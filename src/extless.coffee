fs = require 'fs'
path = require 'path'
loglet = require 'loglet'

extless = (options) ->
  
  (req, res, next) ->
    loglet.log 'REQUEST', req.method, req.url
    # we will just modify the queries... 
    if not (req.url == '/') and not req.url.match /\..+$/
      req.url += '.html'
    loglet.debug 'server.extless', req.url, not (req.url == '/'), not req.url.match /^\..+$/
    next()

module.exports = extless
