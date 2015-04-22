marked = require 'marked'
handlebars = require 'handlebars'
fs = require 'fs'
_ = require 'underscore'
path = require 'path'
loglet = require 'loglet'
funclet = require 'funclet'
filelet = require 'filelet'
watch = require 'watch'
async = require 'async'

isFunction = (v) ->
  typeof(v) == 'function' or v instanceof Function

registerHelpers = (helpers, scope = helpers.name) ->
  for key, val of helpers
    if helpers.hasOwnProperty(key) and isFunction(val)
      name = "#{scope}:#{key}"
      handlebars.registerHelper name, val

handlebars.registerHelper 'ifCond', (v1, operator, v2, options)->
  loglet.log 'ifConf', v1, operator, v2
  switch operator
    when '==', '==='
      return if v1 is v2 then options.fn @ else options.inverse @
    when '<'
      return if v1 < v2 then options.fn @ else options.inverse @
    when '<='
      return if v1 <= v2 then options.fn @ else options.inverse @
    when '>'
      return if v1 > v2 then options.fn @ else options.inverse @
    when '>='
      return if v1 >= v2 then options.fn @ else options.inverse @
    when '&&'
      return if v1 && v2 then options.fn @ else options.inverse @
    when '||'
      return if v1 || v2 then options.fn @ else options.inverse @
    else
      return options.inverse @

handlebars.registerHelper 'json', (v) ->
  JSON.stringify v

handlebars.registerHelper 'showError', (e) ->
  JSON.stringify e

compileTemplate = (filePath, data, cb) ->
  loglet.log 'compileTemplate', filePath
  try 
    ext = path.extname filePath
    templateName = path.join path.dirname(filePath), path.basename(filePath, ext)
    template = 
      if ext == '.md'
        inner = handlebars.compile data 
        (obj) ->
          marked inner(obj)
      else
        handlebars.compile data
    handlebars.registerPartial templateName, template
    cb null
  catch e
    cb e

loadTemplates = (rootPath, options, cb) ->
  if arguments.length == 2
    cb = options
    options = { filter: ['.md', '.hbs', '.js', '.coffee']}
  helper = (filePath, next) ->
    funclet
      .start (next) ->
        fs.readFile path.join(rootPath, filePath), 'utf8', next
      .then (data, next) ->
        compileTemplate filePath, data, next
      .catch(next)
      .done () -> next null
  # we can use this function to determine what files to watch..
  watchOptions = 
    ignoreUnreadableDir: true
    filter: (filePath, stat) -> stat.isFile() and _.find(options.filter, path.extname(filePath))
  #watch.watchTree rootPath, watchOptions, (filePath, curr, prev) ->
  funclet
    .start (next) ->
      filelet.readdirR rootPath, options, next
    .thenEach(helper)
    .catch(cb)
    .done () -> cb null

renderRelKey = (filePath) ->
  path.join path.dirname(filePath), path.basename(filePath, path.extname(filePath))

renderLayout = (body, options, cb) ->
  if options.layout 
    #layoutKey = renderRelKey(options.layout)
    loglet.log 'mdhbs.renderLayout', options.layout, layoutKey, handlebars.partials
    if handlebars.partials.hasOwnProperty(layoutKey)
      layoutTemplate = handlebars.partials[layoutKey]
      data = _.extend { }, options, {body: body}
      cb null, layoutTemplate(data)
    else
      cb null, body
  else
    cb null, body

render = (key, options, cb) ->
  loglet.log 'mdhbs.render', key, handlebars.partials
  if handlebars.partials.hasOwnProperty(key)
    try 
      template = handlebars.partials[key]
      body = template(options)
      renderLayout body, options, cb
    catch e
      cb e
  else
    cb {error: 'unknown_render_template', value: key}

renderKey = (filePath, basePath) ->
  loglet.log 'mdhbs.renderKey', filePath, basePath
  helper = (basePath) ->
    renderRelKey path.relative(basePath, filePath)
  if basePath instanceof Array
    for base in basePath 
      if filePath.indexOf(base) == 0
        return helper base
  else
    helper basePath

fileFilter = (filePath, stat) ->
  ext = path.extname filePath
  stat.isDirectory() or ext == '.md' or ext == '.hbs' or ext == '.js' or ext == '.coffee'

monitors = []

templateEvent = (rootPath, type) ->
  (filePath, stat) ->
    if stat.isFile()
      loglet.log "file.#{type}", filePath
      fs.readFile filePath, 'utf8', (err, data) ->
        if err
          loglet.error "file.#{type}.error", err
        else
          normalized = path.relative rootPath, filePath
          compileTemplate normalized, data, (err) ->
            if err 
              loglet.error "loadTemplate.error", normalized, err

templateCreated = (filePath, stat) ->
  loglet.log 'file.created', filePath, stat
  
templateChanged = (filePath, stat) ->
  loglet.log 'file.changed', filePath, stat

loadTemplateHelper = (rootPath, cb) ->
  fs.stat rootPath, (err, stat) ->
    if err 
      cb null
    else
      funclet
        .bind(loadTemplates, rootPath)
        .then (next) ->
          watch.createMonitor rootPath, {filter: fileFilter}, (monitor) ->
            monitors.push monitor
            monitor.on 'created', templateEvent(rootPath, 'created')
            monitor.on 'changed', templateEvent(rootPath, 'changed')
            next null
        .catch(cb)
        .done(() -> cb null)

baseViews = 
  for item in ['views', 'template']
    path.join(process.cwd(), item)

_renderFile = (filePath, options, cb) ->
  loglet.log 'renderFile', filePath
  key = renderKey filePath, options?.settings?.views or baseViews
  if handlebars.partials.hasOwnProperty(key)
    render key, options, cb
  else if path.extname(filePath) == '.html'
    # we will load things *especially*... 
    fs.readFile filePath, 'utf8', (err, body) ->
      if err
        cb err
      else
        renderLayout body, options, cb
  else
    rootPaths = options?.settings?.views or baseViews
    funclet
      .each(rootPaths, loadTemplateHelper)
      .catch(cb)
      .done () ->
        render key, options, cb

isAbsolute = (filePath) ->
  filePath.indexOf('/') == 0

renderFile = (filePath, options, cb) ->
  if isAbsolute(filePath)
    _renderFile filePath, options, cb
  else
    async.detect (path.join(base, filePath) for base in options?.settings?.views or baseViews), fs.exists, (fullPath) ->
      if not fullPath
        cb {error: 'unknown_render_template', path: filePath}
      else
        _renderFile fullPath, options, cb

module.exports = 
  loadTemplates: loadTemplates
  handlebars: handlebars
  __express: renderFile
  renderFile: renderFile
  registerHelpers: registerHelpers

