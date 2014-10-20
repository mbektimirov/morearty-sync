B = require 'backbone'
Imm = require 'immutable'
Morearty = require 'morearty'
{Binding, History} = Morearty

defaultSync = B.sync

isEmptyObject = (obj) ->
  Object.getOwnPropertyNames(obj).length == 0

methodMap =
  'create': 'creating'
  'update': 'updating'
  'patch' : 'patching'
  'delete': 'deleting'
  'read'  : 'reading'

B.sync = (method, model, @options = {}) ->
  xhr = defaultSync method, model, options

  if model instanceof SyncModel
    model.updateStatus method
    xhr
      .success -> model.unsetIfExists 'error'
      .fail (e, error, errorMessage) ->
        # TODO: merge previous state instead of undo, 'status' and 'error' make binding dirty
        model.history?.undo() if options.rollback
        model.set 'error', Imm.fromJS(errorMessage || 'Unknown error')

      .always -> model.updateStatus null


validateModel = (ModelOrCollectionClass, BaseClass, type) ->
  if ModelOrCollectionClass != BaseClass
    if !(ModelOrCollectionClass.prototype instanceof BaseClass)
      throw new Error "#{type} should be instance of #{BaseClass.name}"



class SyncModel extends B.Model
  ###
  @param {Binding|Object} data - representing the model data. For raw object new binding will be created.
  ###
  constructor: (data, options = {}) ->
    @binding =
      if data instanceof Binding
        data
      else
        # TODO: For now new binding is created if model is new. In this case binding
        # should be pointed to Vector entry when model data goes to collection.
        # The main question is: leave it as is or do not create own binding
        # for empty model and then strictly bind it to main state?
        data = @parse(data, options) || {} if options.parse
        Binding.init Imm.fromJS(data)

    # TODO: rewrite Morearty.History class
    @_historyBinding = Binding.init()
    @history = History.init @binding, @_historyBinding

    Object.defineProperties @,
      'id':
        writeable: false
        get: ->
          @get @idAttribute || 'id'

        set: (id) ->
          @set(@idAttribute || 'id', id)

    @initialize.apply @, arguments

  get: (key) ->
    value = @binding.val key
    if value instanceof Imm.Sequence then value.toJSON() else value

  set: (key, val, options) ->
    return @ unless key
    {attrs, options} = @_attrsAndOptions key, val, options

    # Protect from empty merge which triggers binding listeners
    return if isEmptyObject attrs

    if options.unset
      tx = @binding.atomically()
      tx = tx.delete k for k of attrs
      tx.commit options.silent # should be strictly false to silent listeners
    else
      @binding.merge Imm.fromJS(attrs)

    # Speculative update: set first, then validate
    validationError = @validate?(@toJSON())

    if validationError
      @binding.set 'validationError', Imm.fromJS(validationError)
    else
      @unsetIfExists 'validationError'

    @


  toJSON: ->
    json = @binding.val().toJSON()
    delete json[k] for k in ['status', 'validationError']
    json

  unsetIfExists: (key) ->
    @unset key if @get key

  # Write model data to the new binding and point @binding to it
  bindTo: (newBinding) ->
    newBinding.set @binding.val()
    @binding = newBinding

  isPending: ->
    @get('status')

  updateStatus: (method) ->
    if @options.xhrStatus
      if method
        @set 'status', methodMap[method]
      else
        @unsetIfExists 'status'

  _attrsAndOptions: (key, val, options) ->
    # Handle both `"key", value` and `{key: value}` -style arguments.
    # (from Backbone.Model.set)
    attrs = {}
    if typeof key == 'object'
      attrs = key
      options = val
    else
      attrs[key] = val

    attrs: attrs
    options: options || {}


###
!!! WARNING !!!
Don't use this. I will come up with a better solution later.
For now it is broken by design and implementation.
###
class SyncCollection extends B.Collection
  model: SyncModel

  constructor: (@vectorBinding, options = {}) ->
    if !@vectorBinding instanceof Binding
      throw new Error 'Pass Binding instance as a first argument'

    validateModel @model, SyncModel, 'model'

    # @_reset()
    # models = @extractModelBindings().map ((binding) -> new @model binding), @
    super @extractModelBindings()
    @_syncWithBinding()


  _syncWithBinding: ->
    # Track only root vector binding changes
    @vectorBinding.addGlobalListener (_, __, absolutePath, relativePath) =>
      if !relativePath
        @_updateModels()

    @listenTo @, 'add', (model, collection, options) =>
      @_onAdd model, options

    @listenTo @, 'remove', (model, collection, options) ->
      @_onRemove model, options

    @listenTo @, 'reset', (collection, options) ->
      @_onReset options


  extractModelBindings: ->
    [0...@vectorBinding.val().length].map (i) => @vectorBinding.sub(i)

  _onAdd: (models, options) ->
    # TODO: add merge
    immData = @_modelsToVector models
    {at} = options

    @vectorBinding.update (v) ->
      if at?
        args = [at, 0].concat immData
        v.splice.apply v, args
      else
        v.concat immData

  _onReset: (options) ->
    # TODO: add silent
    v = @_modelsToVector @models
    @vectorBinding.set v

  _onRemove: (model, options) ->
    @vectorBinding.update (v) ->
      v.splice options.index, 1

  _modelsToVector: (models) ->
    [].concat(models).map (model) -> model.binding.val()


  # As the SyncModel is only a wrapper for binding it may point to different part
  # of data when Vector has updated. In this situation at least model id should be
  # updated as it is binded directly to the Model.
  # If a model is new, binding should be pointed to the Vector entry.
  # TODO: SyncModel.history is useless and danger after collection updates, need more
  # investigation.
  _updateModels: ->
    @models.forEach (model, i) =>
      model.updateId()
      vItemBinding = @vectorBinding.sub i

      # model binding is obsolete after model has been added to collection
      if model.binding != vItemBinding
        model.binding = vItemBinding
        model.history?.clear()


MoreartySync =
  SyncModel: SyncModel
  SyncCollection: SyncCollection

  createContext: ({state, modelMapping, configuration}) ->
    Ctx = Morearty.createContext state, configuration
    Ctx._modelMap = {}
    Ctx._modelMapRegExps = []

    for {path, model} in modelMapping
      # validateModel ModelOrCollection, SyncModel, 'model'
      # validateModel ModelOrCollection, SyncCollection, 'collection'
      ModelOrCollection = model

      # just split by reg-exps and normal paths
      if path instanceof RegExp
        Ctx._modelMapRegExps.push pathRegExp: path, model: ModelOrCollection
      else
        Ctx._modelMap[path] = ModelOrCollection

    Ctx

  Mixin:
    # lazy model retrieval
    model: (binding = @getDefaultBinding()) ->
      ctx = @context.morearty
      path = Binding.asStringPath binding._path

      model =
        if ModelOrCollection = ctx._modelMap[path]
          new ModelOrCollection binding
        else if matched = path.match /(.*)\.(\d+)/
          # check if path is a vector item: some.list.x
          [__, vectorPath, itemIndex] = matched
          collection = ctx._modelMap[vectorPath]
          model = collection?.at itemIndex
        else
          # check in regexps
          MClass =
            (ctx._modelMapRegExps.filter (rx) ->
              path.match rx.pathRegExp
            )[0]?.model

          # TODO: cache it or not?
          new MClass binding if MClass

    collection: (binding) ->
      @model binding


module.exports = MoreartySync
