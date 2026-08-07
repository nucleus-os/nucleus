'use strict';

// Nucleus Settings shim.
// Mirror the iOS Settings.js API, persisting via NativeSettingsManager
// and proactively emitting 'settingsUpdated' so watchers fire.

// Use defensive pattern to avoid "Cannot read property 'default' of undefined"
const RCTDeviceEventEmitterRaw = require('react-native/Libraries/EventEmitter/RCTDeviceEventEmitter');
const RCTDeviceEventEmitter =
  RCTDeviceEventEmitterRaw && RCTDeviceEventEmitterRaw.__esModule
    ? RCTDeviceEventEmitterRaw.default
    : RCTDeviceEventEmitterRaw;

const NativeSettingsManagerRaw = require('react-native/Libraries/Settings/NativeSettingsManager');
const NativeSettingsManagerModule =
  NativeSettingsManagerRaw && NativeSettingsManagerRaw.__esModule
    ? NativeSettingsManagerRaw.default
    : NativeSettingsManagerRaw;

const NativeSettingsManager = NativeSettingsManagerModule;

const subscriptions = [];

const Settings = {
  _settings: (NativeSettingsManager && NativeSettingsManager.getConstants().settings) || {},

  get(key) {
    return this._settings[key];
  },

  set(settings) {
    // Merge into local cache first so getters reflect the change immediately.
    this._settings = Object.assign({}, this._settings, settings);
    try {
      // Persist via native (C++ module writes to disk in Nucleus host).
      NativeSettingsManager &&
        NativeSettingsManager.setValues &&
        NativeSettingsManager.setValues(settings);
    } finally {
      // Proactively emit the standard update event so watchers fire.
      RCTDeviceEventEmitter &&
        RCTDeviceEventEmitter.emit &&
        RCTDeviceEventEmitter.emit('settingsUpdated', settings);
    }
  },

  watchKeys(keys, callback) {
    if (typeof keys === 'string') keys = [keys];
    if (!Array.isArray(keys)) {
      throw new Error('keys should be a string or array of strings');
    }
    const sid = subscriptions.length;
    subscriptions.push({ keys, callback });
    return sid;
  },

  clearWatch(watchId) {
    if (watchId < subscriptions.length) {
      subscriptions[watchId] = { keys: [], callback: null };
    }
  },

  _sendObservations(body) {
    Object.keys(body).forEach((key) => {
      const newValue = body[key];
      const didChange = this._settings[key] !== newValue;
      this._settings[key] = newValue;
      if (didChange) {
        subscriptions.forEach((sub) => {
          if (sub.keys.indexOf(key) !== -1 && sub.callback) {
            sub.callback();
          }
        });
      }
    });
  },
};

// Also listen for native-originated updates if they arrive.
if (RCTDeviceEventEmitter && RCTDeviceEventEmitter.addListener) {
  RCTDeviceEventEmitter.addListener('settingsUpdated', Settings._sendObservations.bind(Settings));
}

module.exports = Settings;
