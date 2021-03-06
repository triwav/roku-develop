http  = require 'http'
dgram = require 'dgram'

# RegEx to extract ip addr/serial number from M-SEARCH and NOTIFY responses
reIpAddr        = /\r\nLocation\s*:\s*(?:.*?:\/\/)?([^:\/\r\n]+)/i
reSerialNumber  = /\r\nUSN:\s*uuid:roku:ecp:\s*([A-Z0-9]+)/i

# Use a regular expression to extract a field from some data,
# returning an empty string if the field is not found
extract = (re, data) ->
  m = re.exec data
  if Array.isArray(m) and m.length is 2 then m[1] else ''

# Extract device details from a device's ECP response
# Not terribly efficient, but it doesn't need to be
parseDeviceDetails = (ipAddr, serialNumber, data) ->
  sn = serialNumber or extract(/<serialNumber>(.*?)<\/serialNumber>/i, data)
  {
    ipAddr:         ipAddr
    serialNumber:   sn
    friendlyName:   extract(/<friendlyName>(.*?)<\/friendlyName>/i, data)
    modelName:      extract(/<modelName>(.*?)<\/modelName>/i, data)
    modelNumber:    extract(/<modelNumber>(.*?)<\/modelNumber>/i, data)
  }

# Send an ECP request to the device to get its details
# Invoke the callback to pass the device details back to the caller
deviceDiscovered = (ipAddr, serialNumber, discoveryCallback, autoDiscover) ->
  bufferList = []
  req = http.request({host: ipAddr, port: 8060, family: 4}, (res) =>
    res.on('data', (chunk) =>
      bufferList.push chunk
    )
    res.on('end', () =>
      response = Buffer.concat(bufferList).toString()
      details = parseDeviceDetails ipAddr, serialNumber, response
      if details.serialNumber
        discoveryCallback details, autoDiscover
    )
  )

  # A 'socket' event is emitted after a socket is assigned to the request
  # Handle this event to set a timeout on the socket connection
  # This is instead of setting the timeout when http.request() is called,
  # which would only be emitted after the socket is assigned and is connected,
  # and would not detect a timeout while trying to establish the connection
  req.on('socket', (socket) =>
    socket.setTimeout 10000
    socket.on('timeout', () =>
      console.log 'deviceDiscovered socket timeout'
      # A timeout does not abort the connection; it has to be done manually
      # This will cause a createHangUpError error to be emitted on the request
      req.abort()
    )
  )

  # Even if there is an error on the ECP request, invoke the
  # discoveryCallback with the known ip address and serial number
  req.on('error', (error) =>
    details = parseDeviceDetails ipAddr, serialNumber, ''
    if details.serialNumber
      discoveryCallback details, autoDiscover
    console.warn 'ECP request to %s failed: %O', ipAddr, error
  )

  # The ECP request has an empty body
  req.write('')

  # Send the ECP request
  req.end()

# Send an SSDP M-SEARCH discovery request
ssdpSearchRequest = (discoveryCallback) ->
  ssdpRequest = new Buffer(
                'M-SEARCH * HTTP/1.1\r\n\
                 HOST: 239.255.255.250:1900\r\n\
                 MAN: "ssdp:discover"\r\n\
                 ST: roku:ecp\r\n\
                 MX: 3\r\n\
                 \r\n'\
                 )

  searchSocket = dgram.createSocket 'udp4'

  searchSocket.on('message', (msg, rinfo) =>
    ssdpResponse = msg.toString()
    serialNumber = extract reSerialNumber, ssdpResponse
    ipAddr = extract reIpAddr, ssdpResponse
    #console.log 'M-SEARCH Response:', ssdpResponse
    # Only add devices that have an ip address and serial number
    # This will trigger an ECP request to get the device details
    if ipAddr and serialNumber
      deviceDiscovered ipAddr, serialNumber, discoveryCallback, true
  )

  # Send the M-SEARCH request to the SSDP multicast group
  searchSocket.send ssdpRequest, 1900, '239.255.255.250'

# Listen for SSDP discovery NOTIFY responses
# These should be received whenever a device connects to the network
ssdpNotify = (discoveryCallback) ->
  notifySocket = dgram.createSocket {type: 'udp4', reuseAddr: true}

  notifySocket.on('message', (msg, rinfo) =>
    ssdpResponse = msg.toString()
    #console.log 'NOTIFY response', ssdpResponse
    serialNumber = extract reSerialNumber, ssdpResponse
    ipAddr = extract reIpAddr, ssdpResponse

    # Only add devices that have an ip address AND Roku serial number,
    # to avoid sending ECP requests to non-Roku devices.
    if ipAddr and serialNumber
      deviceDiscovered ipAddr, serialNumber, discoveryCallback, true
  )

  # Handle errors on the NOTIFY socket
  # Note that in some cases an exception may be thrown,
  # hence the try-catch statement in the bind callback
  notifySocket.on('error', (err) =>
    console.warn 'NOTIFY -- error: %O', err
  )

  # SSDP NOTIFY responses are directed to port 1900
  notifySocket.bind(1900, () =>
    try
      # Prevent receipt of local SSDP M-SEARCH requests
      notifySocket.setMulticastLoopback false

      # Join the SSDP multicast group so we can receive SSDP NOTIFY responses
      notifySocket.addMembership '239.255.255.250'
    catch e
      console.warn 'NOTIFY -- bind exception: %O', e
  )

  # If the network connection drops, then no further NOTIFY responses
  # will be received on the bound port
  # Since there is no indication of a network connection failure,
  # after a predetermined timeout, close then re-establish the connection
  setTimeout( () =>
    try
      notifySocket.close( () => ssdpNotify discoveryCallback )
    catch e
      console.warn 'NOTIFY -- Exception when trying to close socket: %O', e
  , 5 * 60 * 1000 )

# The SSDP protocol, which uses UDP datagrams, is inherently flaky
# M-SEARCH responses are not guaranteed to be received.
# To make allowances for this, send out multiple M-SEARCH requests
ssdpSearch = (discoveryCallback) ->
  setTimeout ssdpSearchRequest, 0, discoveryCallback
  setTimeout ssdpSearchRequest, 15000, discoveryCallback
  setTimeout ssdpSearchRequest, 30000, discoveryCallback
  #setInterval ssdpSearchRequest, 120000, discoveryCallback

class RokuSSDP

  # Initiate SSDP discovery
  @discover = (discoveryCallback) ->
    ssdpSearch discoveryCallback
    ssdpNotify discoveryCallback

  # Attempt to acquire device details from a user-entered, non-discovered
  # device, for which the serial number is unknown
  @ecp = (ipAddr, discoveryCallback) ->
    deviceDiscovered ipAddr, '', discoveryCallback, false

module.exports = RokuSSDP
