import 'dart:io';
import 'dart:typed_data';

import 'package:pedantic/pedantic.dart';

import 'dbus_address.dart';
import 'dbus_auth_server.dart';
import 'dbus_bus_name.dart';
import 'dbus_introspect.dart';
import 'dbus_introspectable.dart';
import 'dbus_match_rule.dart';
import 'dbus_message.dart';
import 'dbus_method_response.dart';
import 'dbus_peer.dart';
import 'dbus_properties.dart';
import 'dbus_read_buffer.dart';
import 'dbus_uuid.dart';
import 'dbus_value.dart';
import 'dbus_write_buffer.dart';

/// Server-only error responses.
class _DBusServerErrorResponse extends DBusMethodErrorResponse {
  _DBusServerErrorResponse.serviceUnknown([String? message])
      : super('org.freedesktop.DBus.Error.ServiceUnknown',
            message != null ? [DBusString(message)] : []);

  _DBusServerErrorResponse.serviceNotFound([String? message])
      : super('org.freedesktop.DBus.Error.ServiceNotFound',
            message != null ? [DBusString(message)] : []);

  _DBusServerErrorResponse.nameHasNoOwner([String? message])
      : super('org.freedesktop.DBus.Error.NameHasNoOwner',
            message != null ? [DBusString(message)] : []);

  _DBusServerErrorResponse.matchRuleInvalid([String? message])
      : super('org.freedesktop.DBus.Error.MatchRuleInvalid',
            message != null ? [DBusString(message)] : []);

  _DBusServerErrorResponse.matchRuleNotFound([String? message])
      : super('org.freedesktop.DBus.Error.MatchRuleNotFound',
            message != null ? [DBusString(message)] : []);
}

/// A client connected to a D-Bus server.
class _DBusRemoteClient {
  /// The socket this client connected on.
  final _DBusServerSocket serverSocket;

  /// The socket this client is communicating on.
  final Socket _socket;

  /// Incoming data.
  final _readBuffer = DBusReadBuffer();

  /// Authentication server.
  final DBusAuthServer _authServer;

  /// True when have received a Hello message.
  bool receivedHello = false;

  /// Unique name of this client.
  final String uniqueName;

  /// Message match rules.
  final matchRules = <DBusMatchRule>[];

  _DBusRemoteClient(this.serverSocket, this._socket, this.uniqueName)
      : _authServer = DBusAuthServer(serverSocket.uuid) {
    _authServer.responses.listen((message) => _socket.write(message + '\r\n'));
    _socket.listen(_processData);
  }

  /// True if this client wants to receive [message].
  bool matchMessage(DBusMessage message) {
    if (message.destination == uniqueName) {
      return true;
    }
    for (var rule in matchRules) {
      // FIXME(robert-ancell): Check if sender matches unique name like in client
      if (rule.match(
          type: message.type,
          sender: message.sender,
          interface: message.interface,
          member: message.member,
          path: message.path)) return true;
    }
    return false;
  }

  /// Send [message] to this client.
  void sendMessage(DBusMessage message) {
    var buffer = DBusWriteBuffer();
    buffer.writeMessage(message);
    _socket.add(buffer.data);
  }

  Future<void> close() async {
    await _socket.close();
  }

  /// Processes incoming data from this D-Bus client.
  void _processData(Uint8List data) {
    _readBuffer.writeBytes(data);

    var complete = false;
    while (!complete) {
      if (!_authServer.isAuthenticated) {
        complete = _processAuth();
      } else {
        complete = _processMessages();
      }
      _readBuffer.flush();
    }
  }

  /// Processes authentication messages received from the D-Bus client.
  bool _processAuth() {
    var line = _readBuffer.readLine();
    if (line == null) {
      return true;
    }

    _authServer.processRequest(line);
    return false;
  }

  bool _processMessages() {
    var start = _readBuffer.readOffset;
    var message = _readBuffer.readMessage();
    if (message == null) {
      _readBuffer.readOffset = start;
      return true;
    }

    // Ensure the sender field is set and is correct.
    var m = DBusMessage(message.type,
        flags: message.flags,
        serial: message.serial,
        path: message.path,
        interface: message.interface,
        member: message.member,
        errorName: message.errorName,
        replySerial: message.replySerial,
        destination: message.destination,
        sender: uniqueName,
        values: message.values);
    serverSocket.server._processMessage(m);

    return false;
  }
}

/// A socket for incoming D-Bus server connections.
class _DBusServerSocket {
  /// The server this socket is listening for.
  final DBusServer server;

  /// Socket being listened on.
  final ServerSocket socket;

  /// Id for this connection.
  final int connectionId;

  /// Next Id to use to generate a unique name for each client.
  int _nextClientId = 0;

  /// Unique ID for this socket.
  final uuid = DBusUUID();

  /// Connected clients.
  final _clients = <_DBusRemoteClient>[];

  _DBusServerSocket(this.server, this.socket, this.connectionId) {
    socket.listen((clientSocket) {
      var uniqueName = ':$connectionId.$_nextClientId';
      _nextClientId++;
      _clients.add(_DBusRemoteClient(this, clientSocket, uniqueName));
    });
  }

  Future<void> close() async {
    await socket.close();

    /// Delete the file used by Unix sockets.
    if (socket.address.type == InternetAddressType.unix) {
      await File(socket.address.host).delete();
    }
  }
}

/// An open request for a name.
class _DBusNameRequest {
  /// True if this client allows another client to take this name.
  bool allowReplacement;

  /// True if this client will take a name off another client.
  bool replaceExisting;

  /// True if this client wants to be removed from the queue if not the owner.
  bool doNotQueue;

  _DBusNameRequest(
      this.allowReplacement, this.replaceExisting, this.doNotQueue);
}

/// A queue of clients requesting a name.
class _DBusNameQueue {
  /// The name being queued for.
  final String name;

  /// Queued requests.
  final requests = <_DBusRemoteClient, _DBusNameRequest>{};

  /// The current owner of this name.
  _DBusRemoteClient? get owner =>
      requests.isNotEmpty ? requests.keys.first : null;

  /// Creates a new name queue for [name].
  _DBusNameQueue(this.name);

  /// Add/update a request from [client] for this name.
  void addRequest(_DBusRemoteClient client, bool allowReplacement,
      bool replaceExisting, bool doNotQueue) {
    var currentOwner = owner;

    var request = requests[client];
    if (request == null) {
      request = _DBusNameRequest(allowReplacement, replaceExisting, doNotQueue);
      requests[client] = request;
    }
    request.allowReplacement = allowReplacement;
    request.replaceExisting = replaceExisting;
    request.doNotQueue = doNotQueue;

    // If can take an existing name, move to the front of the queue
    if (currentOwner != null &&
        currentOwner != client &&
        requests[currentOwner]!.allowReplacement &&
        replaceExisting) {
      requests.remove(client);
      var otherRequests = requests.entries.toList();
      requests.clear();
      requests[client] = request;
      requests.addEntries(otherRequests);
    }

    /// Purge any do not queue requests.
    requests.removeWhere(
        (client, request) => client != owner && request.doNotQueue);
  }

  /// Returns true if [client] has a request on this name.
  bool hasRequest(_DBusRemoteClient client) => requests.containsKey(client);

  /// Remove a request from [client] for this name.
  /// Returns true if there was a reuest to remove.
  bool removeRequest(_DBusRemoteClient client) {
    return requests.remove(client) != null;
  }
}

/// A D-Bus server.
class DBusServer {
  /// Sockets being listened on.
  final _sockets = <_DBusServerSocket>[];

  /// Next Id to use for connections.
  int _nextConnectionId = 1;

  /// Connected clients.
  Iterable<_DBusRemoteClient> get _clients =>
      _sockets.map((s) => s._clients).expand((c) => c);

  /// Next serial number to use for messages from the server.
  int _nextSerial = 1;

  /// Queues for name ownership.
  final _nameQueues = <String, _DBusNameQueue>{};

  /// Feature flags exposed by the server.
  final _features = <String>[];

  /// Interfaces supported by the server.
  final _interfaces = <String>[];

  /// Creates a new DBus server.
  DBusServer();

  /// Listen on the given D-Bus [address].
  Future<void> listenAddress(String address) async {
    var address_ = DBusAddress.fromString(address);
    switch (address_.transport) {
      case 'unix':
        var path = address_.properties['path'];
        if (path == null) {
          throw FormatException('Missing Unix path in D-Bus address');
        }
        await listenUnixSocket(path);
        break;
      case 'tcp':
        var bindAddress =
            address_.properties['bind'] ?? address_.properties['host'];
        if (bindAddress == null) {
          throw FormatException('Missing bind or host in D-Bus address');
        }
        int port;
        try {
          port = int.parse(address_.properties['port'] ?? '0');
        } on FormatException {
          throw FormatException('Invalid port number in D-Bus address');
        }

        await listenTcpSocket(address: bindAddress, port: port);

        break;
      default:
        throw FormatException(
            "Unknown D-Bus transport '${address_.transport}'");
    }
  }

  /// Listens for connections on a Unix socket at [path].
  /// If [path] is not provided a random path is chosen.
  /// Returns the D-Bus address for clients to connect to this socket.
  Future<String> listenUnixSocket([String? path]) async {
    if (path == null) {
      var directory = await Directory.systemTemp.createTemp();
      path = '${directory.path}/dbus-socket';
    }
    var address = InternetAddress(path, type: InternetAddressType.unix);
    await _addServerSocket(address, 0);
    return 'unix:path=$path';
  }

  /// Listens for connections on a TCP/IP socket.
  Future<String> listenTcpSocket(
      {String? address, int port = 0, type = InternetAddressType.any}) async {
    InternetAddress anyAddress;
    String? family;
    switch (type) {
      case InternetAddressType.any:
        anyAddress = InternetAddress.anyIPv4;
        break;
      case InternetAddressType.IPv4:
        anyAddress = InternetAddress.anyIPv4;
        family = 'ipv4';
        break;
      case InternetAddressType.IPv6:
        anyAddress = InternetAddress.anyIPv6;
        family = 'ipv6';
        break;
      default:
        throw "Unsupported adddress type '$type'";
    }

    InternetAddress address_;
    if (address != null) {
      var addresses = await InternetAddress.lookup(address, type: type);
      if (addresses.isEmpty) {
        throw "Failed to resolve host '$address'";
      }
      address_ = addresses[0];
    } else {
      address_ = anyAddress;
    }
    var serverSocket = await _addServerSocket(address_, port);
    var addressText =
        'tcp:host=${address ?? 'localhost'},port=${serverSocket.socket.port}';
    if (family != null) {
      addressText += ',family=$family';
    }
    return addressText;
  }

  Future<_DBusServerSocket> _addServerSocket(
      InternetAddress address, int port) async {
    var socket = await ServerSocket.bind(address, 0);
    var serverSocket = _DBusServerSocket(this, socket, _nextConnectionId);
    _sockets.add(serverSocket);
    _nextConnectionId++;
    return serverSocket;
  }

  /// Terminates all active connections. If a server remains unclosed, the Dart process may not terminate.
  Future<void> close() async {
    for (var socket in _sockets) {
      await socket.close();
    }
  }

  /// Get the client that is currently owning [name].
  _DBusRemoteClient? _getClientByName(String name) {
    for (var client in _clients) {
      if (client.uniqueName == name) {
        return client;
      }
    }
    return _nameQueues[name]?.owner;
  }

  /// Process an incoming message.
  Future<void> _processMessage(DBusMessage message) async {
    // Forward to any clients that are listening to this message.
    for (var client in _clients) {
      if (client.matchMessage(message)) {
        client.sendMessage(message);
      }
    }

    // Process requests for the server.
    DBusMethodResponse? response;
    var client = _getClientByName(message.sender!);
    if (client != null &&
        !client.receivedHello &&
        !(message.destination == 'org.freedesktop.DBus' &&
            message.interface == 'org.freedesktop.DBus' &&
            message.member == 'Hello')) {
      await client.close();
      response = DBusMethodErrorResponse.accessDenied(
          'Client tried to send a message other than Hello without being registered');
    } else if (message.destination == 'org.freedesktop.DBus') {
      if (message.type == DBusMessageType.methodCall) {
        response = await _processServerMethodCall(message);
      }
    } else {
      // No-one is going to handle this message.
      if (message.destination != null &&
          _getClientByName(message.destination!) == null) {
        response = _DBusServerErrorResponse.serviceUnknown(
            'The name ${message.destination} is not registered');
      }
    }

    // Send a response message if one generated.
    if (response != null) {
      var type = DBusMessageType.methodReturn;
      String? errorName;
      var values = const <DBusValue>[];
      if (response is DBusMethodSuccessResponse) {
        values = response.values;
      } else if (response is DBusMethodErrorResponse) {
        type = DBusMessageType.error;
        errorName = response.errorName;
        values = response.values;
      }
      var responseMessage = DBusMessage(type,
          flags: {DBusMessageFlag.noReplyExpected},
          serial: _nextSerial,
          errorName: errorName,
          replySerial: message.serial,
          destination: message.sender,
          sender: 'org.freedesktop.DBus',
          values: values);
      _nextSerial++;
      unawaited(_processMessage(responseMessage));
    }
  }

  /// Process a method call requested on the D-Bus server.
  Future<DBusMethodResponse> _processServerMethodCall(
      DBusMessage message) async {
    if (message.interface == 'org.freedesktop.DBus') {
      switch (message.member) {
        case 'Hello':
          return _hello(message);
        case 'RequestName':
          if (message.signature != DBusSignature('su')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var name = (message.values[0] as DBusString).value;
          var flags = (message.values[1] as DBusUint32).value;
          var allowReplacement = (flags & 0x01) != 0;
          var replaceExisting = (flags & 0x02) != 0;
          var doNotQueue = (flags & 0x04) != 0;
          return _requestName(
              message, name, allowReplacement, replaceExisting, doNotQueue);
        case 'ReleaseName':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var name = (message.values[0] as DBusString).value;
          return _releaseName(message, name);
        case 'ListQueuedOwners':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var name = (message.values[0] as DBusString).value;
          return _listQueuedOwners(message, name);
        case 'ListNames':
          if (message.values.isNotEmpty) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          return _listNames(message);
        case 'ListActivatableNames':
          if (message.values.isNotEmpty) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          return _listActivatableNames(message);
        case 'NameHasOwner':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var name = (message.values[0] as DBusString).value;
          return _nameHasOwner(message, name);
        case 'StartServiceByName':
          if (message.signature != DBusSignature('su')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var name = (message.values[0] as DBusString).value;
          var flags = (message.values[1] as DBusUint32).value;
          return _startServiceByName(message, name, flags);
        case 'GetNameOwner':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var name = (message.values[0] as DBusString).value;
          return _getNameOwner(message, name);
        case 'AddMatch':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var rule = (message.values[0] as DBusString).value;
          return _addMatch(message, rule);
        case 'RemoveMatch':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var rule = (message.values[0] as DBusString).value;
          return _removeMatch(message, rule);
        case 'GetId':
          if (message.values.isNotEmpty) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          return _getId(message);
        default:
          return DBusMethodErrorResponse.unknownMethod(
              'Method ${message.interface}.${message.member} not provided');
      }
    } else if (message.interface == 'org.freedesktop.DBus.Introspectable') {
      switch (message.member) {
        case 'Introspect':
          if (message.values.isNotEmpty) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          return _introspect(message);
        default:
          return DBusMethodErrorResponse.unknownMethod(
              'Method ${message.interface}.${message.member} not provided');
      }
    } else if (message.interface == 'org.freedesktop.DBus.Peer') {
      switch (message.member) {
        case 'Ping':
          if (message.values.isNotEmpty) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          return _ping(message);
        case 'GetMachineId':
          if (message.values.isNotEmpty) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          return _getMachineId(message);
        default:
          return DBusMethodErrorResponse.unknownMethod(
              'Method ${message.interface}.${message.member} not provided');
      }
    } else if (message.interface == 'org.freedesktop.DBus.Properties') {
      switch (message.member) {
        case 'Get':
          if (message.signature != DBusSignature('ss')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var interfaceName = (message.values[0] as DBusString).value;
          var name = (message.values[1] as DBusString).value;
          return _propertiesGet(message, interfaceName, name);
        case 'Set':
          if (message.signature != DBusSignature('ssv')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var interfaceName = (message.values[0] as DBusString).value;
          var name = (message.values[1] as DBusString).value;
          var value = (message.values[2] as DBusVariant).value;
          return _propertiesSet(message, interfaceName, name, value);
        case 'GetAll':
          if (message.signature != DBusSignature('s')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          var interfaceName = (message.values[0] as DBusString).value;
          return _propertiesGetAll(message, interfaceName);
        default:
          return DBusMethodErrorResponse.unknownMethod(
              'Method ${message.interface}.${message.member} not provided');
      }
    } else {
      return DBusMethodErrorResponse.unknownInterface(
          'Interface ${message.interface} not provided');
    }
  }

  // Implementation of org.freedesktop.DBus.Hello
  DBusMethodResponse _hello(DBusMessage message) {
    var client = _getClientByName(message.sender!)!;
    if (client.receivedHello) {
      return DBusMethodErrorResponse.failed('Already handled Hello message');
    } else {
      client.receivedHello = true;
      return DBusMethodSuccessResponse([DBusString(message.sender!)]);
    }
  }

  // Implementation of org.freedesktop.DBus.RequestName
  DBusMethodResponse _requestName(DBusMessage message, String name,
      bool allowReplacement, bool replaceExisting, bool doNotQueue) {
    DBusBusName busName;
    try {
      busName = DBusBusName(name);
    } on DBusBusNameException {
      return DBusMethodErrorResponse.invalidArgs(
          "Requested bus name '$name' not valid");
    }
    if (busName.isUnique) {
      return DBusMethodErrorResponse.invalidArgs(
          'Not allowed to request a unique bus name');
    }

    var client = _getClientByName(message.sender!)!;
    var queue = _nameQueues[name];
    var oldOwner = queue?.owner;
    if (queue == null) {
      queue = _DBusNameQueue(name);
      _nameQueues[name] = queue;
    }
    queue.addRequest(client, allowReplacement, replaceExisting, doNotQueue);

    int returnValue;
    if (queue.owner == client) {
      if (oldOwner == client) {
        returnValue = 4; // alreadyOwner
      } else {
        returnValue = 1; // primaryOwner
      }
    } else if (queue.hasRequest(client)) {
      returnValue = 2; // inQueue
    } else {
      returnValue = 3; // exists
    }

    _emitNameSignals(name, oldOwner);

    return DBusMethodSuccessResponse([DBusUint32(returnValue)]);
  }

  // Implementation of org.freedesktop.DBus.ReleaseName
  DBusMethodResponse _releaseName(DBusMessage message, String name) {
    DBusBusName busName;
    try {
      busName = DBusBusName(name);
    } on DBusBusNameException {
      return DBusMethodErrorResponse.invalidArgs(
          "Requested bus name '$name' not valid");
    }
    if (busName.isUnique) {
      return DBusMethodErrorResponse.invalidArgs(
          'Not allowed to release a unique bus name');
    }

    var client = _getClientByName(message.sender!)!;
    var queue = _nameQueues[name];
    var oldOwner = queue?.owner;
    int returnValue;
    if (queue == null) {
      returnValue = 2; // nonExistant
    } else if (queue.removeRequest(client)) {
      // Remove empty queues.
      if (queue.requests.isEmpty) {
        _nameQueues.remove(name);
      }
      returnValue = 1; // released
    } else {
      returnValue = 3; // notOwned
    }

    _emitNameSignals(name, oldOwner);

    return DBusMethodSuccessResponse([DBusUint32(returnValue)]);
  }

  /// Emit signals if [name] is no longer owned by [oldOwner].
  void _emitNameSignals(String name, _DBusRemoteClient? oldOwner) {
    var queue = _nameQueues[name];
    var newOwner = queue?.owner;
    if (oldOwner == newOwner) {
      return;
    }

    _emitNameOwnerChanged(
        name, oldOwner?.uniqueName ?? '', newOwner?.uniqueName ?? '');
    if (oldOwner != null) {
      _emitNameLost(oldOwner.uniqueName, name);
    }
    if (newOwner != null) {
      _emitNameAcquired(newOwner.uniqueName, name);
    }
  }

  // Implementation of org.freedesktop.DBus.ListQueuedOwners
  DBusMethodResponse _listQueuedOwners(DBusMessage message, String name) {
    var queue = _nameQueues[name] ?? _DBusNameQueue('');
    var names =
        queue.requests.keys.map((client) => DBusString(client.uniqueName));
    return DBusMethodSuccessResponse([DBusArray(DBusSignature('s'), names)]);
  }

  // Implementation of org.freedesktop.DBus.ListNames
  DBusMethodResponse _listNames(DBusMessage message) {
    var names = <DBusValue>[DBusString('org.freedesktop.DBus')];
    names.addAll(_clients.map((client) => DBusString(client.uniqueName)));
    names.addAll(_nameQueues.keys.map((name) => DBusString(name)));
    return DBusMethodSuccessResponse([DBusArray(DBusSignature('s'), names)]);
  }

  // Implementation of org.freedesktop.DBus.ListActivatableNames
  DBusMethodResponse _listActivatableNames(DBusMessage message) {
    return DBusMethodSuccessResponse([DBusArray(DBusSignature('s'), [])]);
  }

  // Implementation of org.freedesktop.DBus.NameHasOwner
  DBusMethodResponse _nameHasOwner(DBusMessage message, String name) {
    bool returnValue;
    if (name == 'org.freedesktop.DBus') {
      returnValue = true;
    } else {
      returnValue = _getClientByName(name) != null;
    }
    return DBusMethodSuccessResponse([DBusBoolean(returnValue)]);
  }

  // Implementation of org.freedesktop.DBus.StartServiceByName
  DBusMethodResponse _startServiceByName(
      DBusMessage message, String name, int flags) {
    int returnValue;
    var client = _getClientByName(name);
    if (client != null || name == 'org.freedesktop.DBus') {
      returnValue = 2; // alreadyRunning
    } else {
      // TODO(robert-ancell): Support launching of services.
      return _DBusServerErrorResponse.serviceNotFound();
    }
    return DBusMethodSuccessResponse([DBusUint32(returnValue)]);
  }

  // Implementation of org.freedesktop.DBus.GetNameOwner
  DBusMethodResponse _getNameOwner(DBusMessage message, String name) {
    String? owner;
    if (name == 'org.freedesktop.DBus') {
      owner = 'org.freedesktop.DBus';
    } else {
      var client = _getClientByName(name);
      if (client != null) {
        owner = client.uniqueName;
      }
    }
    if (owner != null) {
      return DBusMethodSuccessResponse([DBusString(owner)]);
    } else {
      return _DBusServerErrorResponse.nameHasNoOwner('Name $name not owned');
    }
  }

  // Implementation of org.freedesktop.DBus.AddMatch
  DBusMethodResponse _addMatch(DBusMessage message, String ruleString) {
    var client = _getClientByName(message.sender!)!;
    DBusMatchRule rule;
    try {
      rule = DBusMatchRule.fromDBusString(ruleString);
    } on DBusMatchRuleException {
      return _DBusServerErrorResponse.matchRuleInvalid();
    }
    client.matchRules.add(rule);
    return DBusMethodSuccessResponse([]);
  }

  // Implementation of org.freedesktop.DBus.RemoveMatch
  DBusMethodResponse _removeMatch(DBusMessage message, String ruleString) {
    var client = _getClientByName(message.sender!)!;
    DBusMatchRule rule;
    try {
      rule = DBusMatchRule.fromDBusString(ruleString);
    } on DBusMatchRuleException {
      return _DBusServerErrorResponse.matchRuleInvalid();
    }
    if (!client.matchRules.remove(rule)) {
      return _DBusServerErrorResponse.matchRuleNotFound();
    }
    return DBusMethodSuccessResponse([]);
  }

  // Implementation of org.freedesktop.DBus.GetId
  DBusMethodResponse _getId(DBusMessage message) {
    var client = _getClientByName(message.sender!)!;
    return DBusMethodSuccessResponse(
        [DBusString(client.serverSocket.uuid.toHexString())]);
  }

  // Implementation of org.freedesktop.DBus.Introspectable.Introspect
  DBusMethodResponse _introspect(DBusMessage message) {
    var dbusInterface =
        DBusIntrospectInterface('org.freedesktop.DBus', methods: [
      DBusIntrospectMethod('Hello', args: [
        DBusIntrospectArgument(
            'unique_name', DBusSignature('s'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('RequestName', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'flags', DBusSignature('u'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'result', DBusSignature('u'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('ReleaseName', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'result', DBusSignature('u'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('ListQueuedOwners', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'names', DBusSignature('as'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('ListNames', args: [
        DBusIntrospectArgument(
            'names', DBusSignature('as'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('ListActivatableNames', args: [
        DBusIntrospectArgument(
            'names', DBusSignature('as'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('NameHasOwner', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'result', DBusSignature('b'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('StartServiceByName', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'flags', DBusSignature('u'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'result', DBusSignature('u'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('GetNameOwner', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.in_),
        DBusIntrospectArgument(
            'owner', DBusSignature('s'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectMethod('AddMatch', args: [
        DBusIntrospectArgument(
            'rule', DBusSignature('s'), DBusArgumentDirection.in_)
      ]),
      DBusIntrospectMethod('RemoveMatch', args: [
        DBusIntrospectArgument(
            'rule', DBusSignature('s'), DBusArgumentDirection.in_)
      ]),
      DBusIntrospectMethod('GetId', args: [
        DBusIntrospectArgument(
            'id', DBusSignature('s'), DBusArgumentDirection.out)
      ])
    ], signals: [
      DBusIntrospectSignal('NameOwnerChanged', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.out),
        DBusIntrospectArgument(
            'old_owner', DBusSignature('s'), DBusArgumentDirection.out),
        DBusIntrospectArgument(
            'new_owner', DBusSignature('s'), DBusArgumentDirection.out)
      ]),
      DBusIntrospectSignal('NameLost', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.out),
      ]),
      DBusIntrospectSignal('NameAcquired', args: [
        DBusIntrospectArgument(
            'name', DBusSignature('s'), DBusArgumentDirection.out),
      ])
    ], properties: [
      DBusIntrospectProperty('Features', DBusSignature('as'),
          access: DBusPropertyAccess.read),
      DBusIntrospectProperty('Interfaces', DBusSignature('as'),
          access: DBusPropertyAccess.read)
    ]);
    var children = <DBusIntrospectNode>[];
    var serverPath = DBusObjectPath('/org/freedesktop/DBus');
    if (message.path != null && serverPath.isInNamespace(message.path!)) {
      children.add(DBusIntrospectNode(
          serverPath.value.substring(message.path!.value.length)));
    }
    var node = DBusIntrospectNode(
        null,
        <DBusIntrospectInterface>[
          dbusInterface,
          introspectIntrospectable(),
          introspectPeer(),
          introspectProperties()
        ],
        children);
    return DBusMethodSuccessResponse([DBusString(node.toXml().toXmlString())]);
  }

  // Implementation of org.freedesktop.DBus.Peer.Ping
  DBusMethodResponse _ping(DBusMessage message) {
    return DBusMethodSuccessResponse();
  }

  // Implementation of org.freedesktop.DBus.Peer.GetMachineId
  Future<DBusMethodResponse> _getMachineId(DBusMessage message) async {
    return DBusMethodSuccessResponse([DBusString(await getMachineId())]);
  }

  // Implementation of org.freedesktop.DBus.Properties.Get
  DBusMethodResponse _propertiesGet(
      DBusMessage message, String interfaceName, String name) {
    if (interfaceName == 'org.freedesktop.DBus') {
      switch (name) {
        case 'Features':
          return DBusGetPropertyResponse(DBusArray(
              DBusSignature('s'), _features.map((value) => DBusString(value))));
        case 'Interfaces':
          return DBusGetPropertyResponse(DBusArray(DBusSignature('s'),
              _interfaces.map((value) => DBusString(value))));
      }
    }
    return DBusMethodErrorResponse.unknownProperty(
        'Properies $interfaceName.$name does not exist');
  }

  // Implementation of org.freedesktop.DBus.Properties.Set
  DBusMethodResponse _propertiesSet(
      DBusMessage message, String interfaceName, String name, DBusValue value) {
    if (interfaceName == 'org.freedesktop.DBus') {
      switch (name) {
        case 'Features':
        case 'Interfaces':
          return DBusMethodErrorResponse.propertyReadOnly();
      }
    }
    return DBusMethodErrorResponse.unknownProperty(
        'Properies $interfaceName.$name does not exist');
  }

  // Implementation of org.freedesktop.DBus.Properties.GetAll
  DBusMethodResponse _propertiesGetAll(
      DBusMessage message, String interfaceName) {
    var properties = <String, DBusValue>{};
    if (interfaceName == 'org.freedesktop.DBus') {
      properties['Features'] = DBusArray(
          DBusSignature('s'), _features.map((value) => DBusString(value)));
      properties['Interfaces'] = DBusArray(
          DBusSignature('s'), _interfaces.map((value) => DBusString(value)));
    }
    return DBusGetAllPropertiesResponse(properties);
  }

  /// Emits org.freedesktop.DBus.NameOwnerChanged.
  void _emitNameOwnerChanged(String name, String oldOwner, String newOwner) {
    _emitSignal(DBusObjectPath('/org/freedesktop/DBus'), 'org.freedesktop.DBus',
        'NameOwnerChanged',
        values: [DBusString(name), DBusString(oldOwner), DBusString(newOwner)]);
  }

  /// Emits org.freedesktop.DBus.NameAcquired.
  void _emitNameAcquired(String destination, String name) {
    _emitSignal(DBusObjectPath('/org/freedesktop/DBus'), 'org.freedesktop.DBus',
        'NameAcquired',
        values: [DBusString(name)], destination: destination);
  }

  /// Emits org.freedesktop.DBus.NameLost.
  void _emitNameLost(String destination, String name) {
    _emitSignal(DBusObjectPath('/org/freedesktop/DBus'), 'org.freedesktop.DBus',
        'NameLost',
        values: [DBusString(name)], destination: destination);
  }

  /// Emits a signal from the D-Bus server.
  void _emitSignal(DBusObjectPath path, String interface, String member,
      {String? destination, List<DBusValue> values = const []}) {
    var message = DBusMessage(DBusMessageType.signal,
        flags: {DBusMessageFlag.noReplyExpected},
        serial: _nextSerial,
        path: path,
        interface: interface,
        member: member,
        destination: destination,
        sender: 'org.freedesktop.DBus',
        values: values);
    _nextSerial++;
    unawaited(_processMessage(message));
  }

  @override
  String toString() {
    return 'DBusServer()';
  }
}
