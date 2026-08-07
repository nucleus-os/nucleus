'use strict';

// Nucleus shim for Fusebox React DevTools dispatcher.
// Upstream version is Flow + uses private class fields and generics.
// Metro in this repo doesn't transform those for Nucleus shims, so keep this file
// plain JS.
//
// Behavior difference vs upstream:
// - Does not throw if __CHROME_DEVTOOLS_FRONTEND_BINDING__ is missing at init.
// - Domain.sendMessage becomes a no-op until binding exists.

class EventScope {
  constructor() {
    this._listeners = new Set();
  }

  addEventListener(listener) {
    this._listeners.add(listener);
  }

  removeEventListener(listener) {
    this._listeners.delete(listener);
  }

  emit(value) {
    for (const listener of this._listeners) {
      listener(value);
    }
  }
}

class Domain {
  constructor(name) {
    this.name = name;
    this.onMessage = new EventScope();
  }

  sendMessage(message) {
    const binding = global[FuseboxReactDevToolsDispatcher.BINDING_NAME];
    if (typeof binding !== 'function') {
      return;
    }
    const messageWithDomain = {domain: this.name, message};
    binding(JSON.stringify(messageWithDomain));
  }
}

class FuseboxReactDevToolsDispatcher {
  static BINDING_NAME = '__CHROME_DEVTOOLS_FRONTEND_BINDING__';
  static onDomainInitialization = new EventScope();
  static _domainNameToDomainMap = new Map();

  static initializeDomain(domainName) {
    const domain = new Domain(domainName);
    this._domainNameToDomainMap.set(domainName, domain);
    this.onDomainInitialization.emit(domain);
    return domain;
  }

  static sendMessage(domainName, message) {
    const domain = this._domainNameToDomainMap.get(domainName);
    if (domain == null) {
      throw new Error(
        `Could not send message to ${domainName}: domain doesn't exist`,
      );
    }

    try {
      domain.onMessage.emit(JSON.parse(message));
    } catch (err) {
      console.error(
        `Error while trying to send a message to domain ${domainName}:`,
        err,
      );
    }
  }
}

// Only define if not already set (supports reload without runtime restart)
if (!global.__FUSEBOX_REACT_DEVTOOLS_DISPATCHER__) {
  Object.defineProperty(global, '__FUSEBOX_REACT_DEVTOOLS_DISPATCHER__', {
    value: FuseboxReactDevToolsDispatcher,
    configurable: false,
    enumerable: false,
    writable: false,
  });
}

module.exports = {
  Domain,
  FuseboxReactDevToolsDispatcher,
};
