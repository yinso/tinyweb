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
mockquery = require 'mockquery'

isFunction = (v) ->
  typeof(v) == 'function' or v instanceof Function

registerHelpers = (helpers, scope = helpers.name) ->
  for key, val of helpers
    if helpers.hasOwnProperty(key) and isFunction(val)
      name = "#{scope}:#{key}"
      registerHelper name, val

registerHelper = (name, proc) ->
  handlebars.registerHelper name, proc

registerHelper 'ifCond', (v1, operator, v2, options)->
  #loglet.log 'ifConf', v1, operator, v2
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

registerHelper 'errorMessage', (context, options) ->
  console.log(' -- iferror', context, options)
  if options?.data?.root?.error?.errors and options.data.root.error.errors.hasOwnProperty(context)
    new handlebars.SafeString options.data.root.error.errors[context]
  else
    new handlebars.SafeString ""

registerHelper 'json', (v) ->
  JSON.stringify v

registerHelper 'showError', (e) ->
  JSON.stringify e

registerHelper 'coalesce', (args...) ->
  for arg in args
    if arg
      return arg
  return

registerHelper 'toggle', (cond, ifTrue, ifFalse) ->
  if cond
    ifTrue
  else
    ifFalse

fileCache = {}

renderParagraph = (renderer) ->
  dropcapRE = /^\s*<span\s+class\s*=\s"dropcap"*/i
  notInParaRE = /^\s*<\s*(figure|caption|table|thead|th|tr|td|ul|ol|address|article|aside|audio|blockquote|dd|div|dl|fieldset|footer|form|h1|h2|h3|h4|h5|h6|header|footer|hr|main|nav|noscript|p|pre|section|video)/i
  (text) ->
    console.log '--renderPara', text, text.match(dropcapRE), text.match(notInParaRE)
    if text.match dropcapRE
      text
    else if text.match notInParaRE
      text
    else
      "<p>#{text}</p>"

renderHTML = (renderer, options) ->
  tableCount = 0
  tablePrefix = () ->
    if options?.prefix and options?.number
      tableCount++
      "#{options.prefix} #{options.number}.#{tableCount} - "
    else
      ''
  (html) ->
    $ = mockquery.load '<root>' + html + '</root>'
    $('[markdown="1"]').each (i, elt) ->
      $(elt).removeAttr 'markdown'
      inner = elt.html()
      rendered = marked inner, {renderer: renderer} # for recursive markdown parsing...
      elt.html rendered
    $('table').each (i, elt) ->
      $(elt).addClass('table')
      captions = $('caption', elt)
      if captions.length > 1
        captions.each (i, elt) ->
          if i == 0
            $(elt).prepend tablePrefix()
          else
            $(elt).remove()
    $('root').html()

newRenderer = (filePath, data) ->
  renderer = new marked.Renderer()
  #renderer.heading = renderHeading(renderer, filePath)
  #renderer.html = renderHTML(renderer, if parsed.number then { number: parsed.number, prefix: 'Table'} else {})
  #renderer.link = renderLink(renderer)
  #renderer.image = renderImage(renderer, if parsed.number then { number: parsed.number, prefix: 'Figure' } else {})
  renderer.paragraph = renderParagraph(renderer)
  renderer.html = renderHTML(renderer)
  renderer


parseMarkdown = (filePath, data) ->
  content = marked data, renderer: newRenderer(filePath, data)



loadFileSync = (filePath, resolvedPath, stat) ->
  console.log '------ load.file', filePath, resolvedPath
  data = fs.readFileSync resolvedPath, 'utf8'
  console.log '------ load.file.data', data
  parsed = parseMarkdown filePath, data
  fileCache[filePath] =
    mtime: stat.mtime
    fullPath: resolvedPath
    parsed: parsed
  parsed

registerHelper 'loadSync', (filePath) ->
  resolvedPath = path.join process.cwd(), filePath
  stat = fs.statSync resolvedPath
  if fileCache.hasOwnProperty(filePath)
    if fileCache[filePath].mtime < stat.mtime
      loadFileSync filePath, resolvedPath, stat
    else
      fileCache[filePath].parsed
  else
    loadFileSync filePath, resolvedPath, stat
    
compileTemplate = (filePath, data, cb) ->
  #loglet.log 'compileTemplate', filePath
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
    layoutKey = renderRelKey(options.layout)
    #loglet.log 'mdhbs.renderLayout', options.layout, layoutKey, handlebars.partials
    if handlebars.partials.hasOwnProperty(layoutKey)
      layoutTemplate = handlebars.partials[layoutKey]
      data = _.extend { }, options, {body: body}
      cb null, layoutTemplate(data)
    else
      cb null, body
  else
    cb null, body

render = (key, options, cb) ->
  #loglet.log 'mdhbs.render', key, handlebars.partials
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
  #loglet.log 'mdhbs.renderKey', filePath, basePath
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
  #loglet.log 'renderFile', filePath
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
  registerHelper: registerHelper

