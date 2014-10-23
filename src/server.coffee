http = require 'http'
express = require 'express'
cookieParser = require 'cookie-parser'
favicon = require 'serve-favicon'
bodyParser = require 'body-parser'
methodOverride = require 'method-override'
extless = require './extless'
path = require 'path'
loglet = require 'loglet'

baseErrorHandler = (options) ->
  (err, req, res, next) ->
    loglet.error 'REQUEST_ERROR', req.method, req.url, req.body, err
    if err.status
      res.statusCode = err.status
    if err.statusCode < 400
      res.statusCode = 500 # ??? why?
    if 'prod' != env
      console.error err.stack
    accept = req.headers.accept or ''
    res.json err.status, err

signedSecret = 'this-is-the-top-secret'
  
run = (argv) ->
  
  loglet.setKeys argv.debug or []
  
  BASE_DIR = process.cwd() # this is the current directory that we are interested in setting up the environment for loading...
  # let's make a static server really quickly... 
  app = express() 

  # these should be read from the local configuration files... we will deal with that later.
  app.set 'url', 'http://localhost'
  app.set 'port', 8080
  app.use cookieParser signedSecret
  app.use bodyParser.json()
  app.use bodyParser.urlencoded({ extended: true })
  app.use methodOverride()
  app.use extless()
  app.use (req, res, next) ->
    loglet.debug 'server.request', req.method, req.url, res.statusCode
    next() 
  app.use express.static(path.join(BASE_DIR, 'public'))
  app.use (req, res, next) ->
    loglet.debug 'server.request', req.method, req.url, res.statusCode
    next() 
  app.use baseErrorHandler({showStack: true, dumpExceptions: true})
  http.createServer(app).listen app.get('port')
  loglet.debug 'server.start', app.get('port')


module.exports = 
  run: run
