# an encrypted cookie session/store.
# depends on the cookieParser.

# NOTE as there are limitations on maximum cookie size, you simply do not want to use this to
# hold arbitrary size objects.

crypto = require 'crypto'
Cookie = require 'cookie'
uuid = require 'node-uuid'

sigSplitter = '~'

newSession = (ts = (new Date()).getTime()) ->
  id: uuid.v4()
  ts: ts

validateTS = (obj, duration) ->
  ts = (new Date()).getTime()
  if obj.ts
    if (duration * 1000) > ts - obj.ts
      obj.ts = ts
      obj
    else
      newSession ts
  else
    newSession ts

decrypt = (encrypted, type, secret, duration) ->
  try
    buffer = []
    encrypted = encrypted.replace(/_/g, '=').replace(/-/g, '/')
    decipher = crypto.createDecipher(type, secret)
    buffer.push decipher.update encrypted, 'base64', 'utf8'
    buffer.push decipher.final 'utf8'
    validateTS JSON.parse(buffer.join('')), duration
  catch e
    newSession()

hashPayload = (payload, secret) ->
  hmac = crypto.createHmac 'sha1', secret
  hmac.update payload + secret + payload
  hmac.digest('hex')

hashVerify = (payload, secret, hash) ->
  digest = hashPayload payload, secret
  digest == hash

decryptCookie = (encrypted, type, secret, duration) ->
  [ payload, sig ] = encrypted.split sigSplitter
  if hashVerify payload, secret, sig
    decrypt payload, type, secret, duration
  else
    newSession()

encrypt = (obj, type, secret) ->
  buffer = []
  payload = JSON.stringify(obj)
  cipher = crypto.createCipher type, secret
  buffer.push cipher.update payload, 'utf8', 'base64'
  buffer.push cipher.final 'base64'
  res = buffer.join('')
  res.replace(/\=/g, '_').replace(/\//g, '-')

encryptCookie = (obj, type, secret) ->
  payload = encrypt obj, type, secret
  hash = hashPayload payload, secret
  payload + sigSplitter + hash

cookieSession = (options) ->
  {key, secret, type, duration, noEncrypt} = options or {}
  cookieOptions = options?.cookie or {path: '/'}
  noEncrypt ||= false
  key ||= 'authme'
  type ||= 'aes192'
  # by default session data itself is valid for 2 weeks (differs from cookie duration)
  duration ||= 2 * 7 * 86400

  (req, res, next) ->
    secret ||= req.secret
    if not secret
      throw new Error("cookieSession:secret_required_in_order_to_encrypt")
    payload = req.cookies[key]
    #console.log 'req.session.raw', req.url, payload
    if payload
      if noEncrypt
        req.session = JSON.parse(payload)
      else
        req.session = decryptCookie payload, type, secret, duration
      #console.log 'req.session.start', req.url, req.session
    else
      req.session = newSession()
    req.sessionID = req.session.id
    hasSentHeaders = false
    res._write = res.write
    res.write = (arg...) ->
      if not hasSentHeaders
        res.emit 'header'
        hasSentHeaders = true
      res._write arg...
    res._end = res.end
    res.end = (arg...) ->
      if not hasSentHeaders
        res.emit 'header'
        hasSentHeaders = true
      res._end arg...

    written = false

    res.on 'header', () ->
      if not written
        cookie =
          if not req.session
            Cookie.serialize(key, '', {expires: new Date(0)})
          else
            if noEncrypt
              Cookie.serialize(key, JSON.stringify(req.session), cookieOptions)
            else
              Cookie.serialize(key, encryptCookie(req.session, type, secret), cookieOptions)
        res.setHeader 'Set-Cookie', cookie
        written = true
    next()

module.exports = cookieSession
