http = require 'http'
https = require 'https'
express = require 'express'
cookieParser = require 'cookie-parser'
favicon = require 'serve-favicon'
bodyParser = require 'body-parser'
session = require 'express-session'
cookieSession = require './session'
methodOverride = require 'method-override'
extless = require './extless'
path = require 'path'
loglet = require 'loglet'
bean =  require 'coffee-bean'
_ = require 'underscore'
fs = require 'fs'
filelet = require 'filelet'
uuid = require 'node-uuid'
mdhbs = require './mdhbs'
wapi = require './wapi'

baseErrorHandler = (options) ->
  (err, req, res, next) ->
    loglet.error 'REQUEST_ERROR', req.method, req.url, req.body, err
    if err.status
      res.statusCode = err.status
    if err.statusCode < 400
      res.statusCode = 500 # ??? why?
    #if 'prod' != env
    console.error err.stack
    accept = req.headers.accept or ''
    res.json err.status, err

signedSecret = 'this-is-the-top-secret'

localRequire = (reqPath) ->
  if reqPath.match /^[^\.\/]+$/ # this is a 3rd-party npm module living in node_modules space...
    require path.join config.BASE_DIR, 'node_modules', reqPath
  else
    require path.join config.BASE_DIR, reqPath

setupSSL = (config, app) ->
  options = _.extend {}, config.https
  options.key = fs.readFileSync path.join config.BASE_DIR, options.key or 'keys/server.key'
  options.cert = fs.readFileSync path.join config.BASE_DIR, options.cert or 'keys/server.crt'
  options.port = options.port or 4443
  loglet.log 'config.https', config.https
  app.set 'ssl', options
  https.createServer(options, app).listen options.port

runStatic = (argv) ->
  app = express()
  app.set 'port', argv.port or 8080
  app.use express.static process.cwd()
  http.createServer(app).listen app.get('port')
  if argv.ssl
    setupSSL argv, app

runWithConfig = (config) ->
  loglet.setKeys config.debug or []
  loglet.log 'tinyweb.runWithConfig', config
  app = express() 
  app.addViews = (viewsDir) ->
    views = app.get 'views'
    views = 
      if views instanceof Array
        views
      else if typeof(views) == 'string'
        [ views ]
      else
        [ ]
    if not _.find views, viewsDir
      views.unshift viewsDir
    app.set 'views', views
  app.set '_config', config
  app.set 'url', config.url or 'http://localhost'
  app.set 'port', config.port or 8080
  app.set 'view engine', config.views?.engine or 'jade' # 
  app.engine 'md', mdhbs.renderFile
  app.engine 'hbs', mdhbs.renderFile
  app.engine 'html', mdhbs.renderFile
  app.engine 'js', mdhbs.renderFile
  app.engine 'coffee', mdhbs.renderFile
  app.renderHelper = mdhbs.registerHelper
  app.hbs = mdhbs
  app.addViews path.join(config.BASE_DIR, config.views?.dir or 'views')
  app.addViews path.join(config.BASE_DIR, 'template')
  app.addViews path.join(config.BASE_DIR, 'public')
  app.use cookieParser config.session?.secret or signedSecret
  sessionConfig = 
    genid: (req) -> uuid.v4()
  _.extend sessionConfig, config.session or {}
  #app.use session sessionConfig
  app.use cookieSession config.session 
  # if I enable server-side session (I can still use client-side session but it'll get up there) I can enable error view pattern.
  # error view -> simply display the error messages.
  # we will separate the validation pattern out... let's try it...
  app.use bodyParser.json()
  app.use bodyParser.urlencoded({ extended: true })
  app.use methodOverride()
  app.use express.static(path.join(config.BASE_DIR, 'public'))
  wapi.init app, config
  initMiddlewares app, config
  initRoutes app, config
  app.use extless()
  app.use baseErrorHandler({showStack: true, dumpExceptions: true})
  initLastMiddlewares app, config
  http.createServer(app).listen app.get('port')
  if config.https
    setupSSL config, app
  loglet.debug 'server.start', app.get('port')

initRoutes = (app, config) ->
  routesPath = path.join config.BASE_DIR, 'routes'
  files = filelet.readdirRSync routesPath
  for file in files
    module = path.basename file, path.extname(file)
    filePath = path.join(config.BASE_DIR, 'routes', module)
    route = require filePath
    route.init app, config, (if module == 'index' then '/' else "/#{module}")

initMiddlewares = (app, config) ->
  middlewarePath = path.join config.BASE_DIR, 'middlewares'
  files = filelet.readdirRSync middlewarePath
  for file in files
    module = path.basename file, path.extname(file)
    filePath = path.join(config.BASE_DIR, 'middlewares', module)
    middleware = require filePath
    middleware.init app, config

initLastMiddlewares = (app, config) ->
  middlewarePath = path.join config.BASE_DIR, 'server'
  files = filelet.readdirRSync middlewarePath
  for file in files
    module = path.basename file, path.extname(file)
    filePath = path.join(config.BASE_DIR, 'server', module)
    middleware = require filePath
    middleware.init app, config

run = (argv) ->
  if argv.static
    runStatic argv
  else
    try
      BASE_DIR = process.cwd() # this is the current directory that we are interested in setting up the environment for loading...
      # let's make a static server really quickly... 
      configPath = path.join(BASE_DIR, argv.config)
      loglet.debug 'server.config', configPath
      config = bean.readFileSync configPath
      config = _.extend config, argv
      config.BASE_DIR = BASE_DIR
      runWithConfig config
    catch err
      loglet.error 'server.config:failed', {error: 'config_load_failed', path: configPath}, err
      process.exit()
  

module.exports = 
  run: run
