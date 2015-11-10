loglet = require 'loglet'
_ = require 'underscore'
url = require 'url'
lruCache = require 'lru-cache'
uuid = require 'node-uuid'

merge = (obj, obj2) ->
  res = {}
  for key, val of obj
    res[key] = val
  for key, val of obj2
    if res.hasOwnProperty(key)
      if res[key] instanceof Array
        if obj2[key] instanceof Array
          res[key] = res[key].concat obj2(key)
        else
          res[key].push obj2[key]
      else if res[key] instanceof Object
        if obj2[key] instanceof Object
          res[key] = merge(res[key], obj2[key])
        else # what to do in the case it's not an object? push it to _. 
          res[key] = merge(res[key], {_: obj2[key]})
      else # neither are objects
        res[key] = [ res[key], obj2[key] ]
    else
      res[key] = val
  res

# how to forciably terminate 


stateKeys =
  return: '*ret'
  continue: '*cnt'
  prg: '*prg'
  layout: '*l'
  edit: '*edit'

class Continuation
  constructor: (@type, @table, @next) ->
    @table.push @
    @id = @table.length() - 1
    @url = "/*continue/#{@table.id}/#{@id}"
  dispose: () ->
    delete @table

class ContinuationTable
  constructor: () ->
    @id = uuid.v4()
    @table = []
  dispose: () ->
    for cont in @table
      cont.dispose()
    delete @table
  push: (cont) ->
    @table.push cont
  makeSuspend: (next) ->
    new Continuation 'suspend', @, next
  makeFinish: (next) ->
    new Continuation 'finish', @, next
  has: (id) ->
    @table.hasOwnProperty(id)
  get: (id) ->
    @table[id]
  del: (id) ->
    delete @table[id]
  length: () ->
    @table.length

contCache = lruCache
  max: 100000
  maxAge: 60 * 60 * 1000
  dispose: (key, table) ->
    table.dispose()

isUUID = (str) ->
  str.match /^[0-9a-zA-Z]{8}-?[0-9a-zA-Z]{4}-?[0-9a-zA-Z]{4}-?[0-9a-zA-Z]{4}-?[0-9a-zA-Z]{12}$/

isInteger = (str) ->
  str.match /^[0-9]+$/

contMatch = (req) ->
  parsed = url.parse req.url
  # we want to care about the part of the path.
  match = parsed.pathname.split '/'
  if match.length == 4 and match[1] == '*continue' and isUUID(match[2]) and isInteger(match[3])
    if contCache.peek(match[2])
      table = contCache.get match[2]
      id = parseInt(match[3])
      if table.has id
        return table.get id
      else
        null
    else
      null
  else
    null

contCreate = () ->
  table = new ContinuationTable
  contCache.set table.id, table
  table

contSuspend = (res, next) ->
  if res.cont
    res.cont.table.makeSuspend next
  else
    table = contCreate()
    table.makeSuspend next

contFinish = (res, next) ->
  if res.cont
    res.cont.table.makeFinish next
  else # this doesn't do anything!
    throw new Error("not_in_a_continuation")

contHandle = (cont, req, res) ->
  req.cont = cont
  res.cont = cont
  cont.next req, res

init = (app, config) ->
  app.set '_config', config
  
  isStateKey = (key) ->
    for k, v of stateKeys
      if key == v
        return true
    false
  
  app.use (req, res, next) ->
    
    res.setHeader 'X-URL', req.url
    
    req._data = merge(req.query, req.body)
    
    req.stateKeys = stateKeys
    
    req.state = {}
    
    removal = {}
    
    normalizeRemoval = (params) ->
      result = {}
      for key, val of params
        if key.indexOf('-') == 0
          removal[key.substring(1)] = true
          result[key.substring(1)] = val
        else
          result[key] = val
      result
    
    removeDashKeys = (data) ->
      result = {}
      for key, val of data
        if not removal.hasOwnProperty(key)
          result[key] = val
      loglet.log 'removeDashKeys', data, removal, result
      result
    
    req.body = normalizeRemoval(req.body or {})
    req.query = normalizeRemoval(req.query or {})
    
    for key, val of stateKeys
      if req._data.hasOwnProperty(val)
        req.state[key] = req._data[val]
        delete req._data[val]
    
    for key, val of req._data
      if key.match /^\*/ # this is a state key...
        req.state[key.substring(1)] = val
    
    res.suspendRender = (view, options, next, reqOptions = {}) ->
      state = req.state
      cont = contSuspend res, (req, res) ->
        for key, val of reqOptions
          if req.hasOwnProperty(key)
            req[key] = _.extend req[key], reqOptions
          else
            req[key] = val
        req.state = _.extend state, req.state or {}
        next req, res
      options = _.extend options, {url: cont.url}
      res.render view, options
    
    res.suspendRedirect = (next, reqOptions = {}) ->
      state = req.state
      cont = contSuspend res, (req, res) ->
        for key, val of reqOptions
          if req.hasOwnProperty(key)
            req[key] = _.extend req[key], val
          else
            req[key] = val
        req.state = _.extend state, req.state or {}
        next req, res
      res.redirect cont.url
    
    res.finishRender = (view, options, next, reqOptions = {}) ->
      state = req.state
      cont = contFinish res, (req, res) ->
        for key, val of reqOptions
          if req.hasOwnProperty(key)
            req[key] = _.extend req[key], reqOptions
          else
            req[key] = val
        req.state = _.extend state, req.state or {}
        next
      options = _.extend options, {url: cont.url}
      res.render view, options
    
    res.genURL = (uri, data = {}, stateFilter = {}) ->
      state = {}
      for key, val of req.state
        if not stateFilter.hasOwnProperty(key) or not stateFilter[key] == false
          state[stateKeys[key]] = val
      
      parsed = url.parse uri
      parsed.query ||= {}
      _.extend parsed.query, state, removeDashKeys(data)
      url.format parsed
    
    res.error = (e) ->
      obj = _.extend {}, e
      if e instanceof Error
        obj.message = e.message
      res.status(e.statusCode or e.code or 500).json e
    
    res.notFound = (e) ->
      loglet.log 'res.notFound', e
      res._error = e
      res.status(404)
      next null
    
    res.internalError = (e) ->
      loglet.log 'res.error', e
      res._error = e
      res.status(500)
      next null
      
    res.requireAuth = (e) ->
      loglet.log 'res.error', e
      res._error = e
      res.status(401)
      next null
    
    res.goto = (uri, obj = {}) ->
      uri = res.genURL uri, obj, {continue: false}
      res.redirect uri
    
    res.clientRedirect = (uri) ->
      res.setHeader 'X-CLIENT-REDIRECT', uri
      content =
        """
        <html>
          <body onload="window.location = '#{uri}'">
            <noscript>
              <meta http-equiv="refresh" content="0; url=#{uri}" />
            </noscript>
          </body>
        </html>
        """
      res.send content
    
    res.result = (obj = {}) ->
      if req.state.continue
        try
          res.goto req.state.continue, obj
        catch e
          loglet.error 'res.result.continue.error', req.url, e
          res.error e
      else
        res.status(200).json obj
    
    res._render = res.render
    
    res.render = (viewName, options) ->
      data = _.extend { user : req.user , error: req._error }, config, options, req.state
      #loglet.log 'res.render.layout', options.layout, data
      res._render viewName , data
    
    res.renderFile = (filePath, options) ->
      res.render filePath, options
    
    # take care of the particular types of data... 
    # * are states. 
    req.getData = (key) ->
      if req.body.hasOwnProperty key
        req.body[key]
      else
        req.query[key]
    
    cont = contMatch req
    if cont instanceof Continuation
      contHandle cont, req, res
    else
      next null
    

module.exports =
  init: init
