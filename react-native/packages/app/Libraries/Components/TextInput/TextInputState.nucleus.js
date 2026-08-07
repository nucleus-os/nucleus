/**
 * Nucleus TextInputState shim.
 *
 * Mirrors react-native's TextInputState but routes focus/blur commands to the
 * Nucleus TextInput native component.
 */
'use strict';

const {Commands: GPUTextInputCommands} = require('./NucleusTextInputNativeComponent.nucleus');
const {findNodeHandle} = require('react-native/Libraries/ReactNative/RendererProxy');

/** @type {any | null} */
let currentlyFocusedInputRef = null;
/** @type {Set<any>} */
const inputs = new Set();

function currentlyFocusedInput() {
  return currentlyFocusedInputRef;
}

function currentlyFocusedField() {
  if (__DEV__) {
    console.error(
      'currentlyFocusedField is deprecated and will be removed in a future release. Use currentlyFocusedInput',
    );
  }

  return findNodeHandle(currentlyFocusedInputRef);
}

function focusInput(textField) {
  if (currentlyFocusedInputRef !== textField && textField != null) {
    currentlyFocusedInputRef = textField;
  }
}

function blurInput(textField) {
  if (currentlyFocusedInputRef === textField && textField != null) {
    currentlyFocusedInputRef = null;
  }
}

function focusField(textFieldID) {
  if (__DEV__) {
    console.error('focusField no longer works. Use focusInput');
  }
}

function blurField(textFieldID) {
  if (__DEV__) {
    console.error('blurField no longer works. Use blurInput');
  }
}

function focusTextInput(textField) {
  if (typeof textField === 'number') {
    if (__DEV__) {
      console.error(
        'focusTextInput must be called with a host component. Passing a react tag is deprecated.',
      );
    }
    return;
  }

  if (textField != null) {
    const fieldCanBeFocused =
      currentlyFocusedInputRef !== textField && textField.currentProps?.editable !== false;

    if (!fieldCanBeFocused) {
      return;
    }

    focusInput(textField);
    GPUTextInputCommands.focus(textField);
  }
}

function blurTextInput(textField) {
  if (typeof textField === 'number') {
    if (__DEV__) {
      console.error(
        'blurTextInput must be called with a host component. Passing a react tag is deprecated.',
      );
    }
    return;
  }

  if (currentlyFocusedInputRef === textField && textField != null) {
    blurInput(textField);
    GPUTextInputCommands.blur(textField);
  }
}

function registerInput(textField) {
  if (typeof textField === 'number') {
    if (__DEV__) {
      console.error(
        'registerInput must be called with a host component. Passing a react tag is deprecated.',
      );
    }
    return;
  }
  inputs.add(textField);
}

function unregisterInput(textField) {
  if (typeof textField === 'number') {
    if (__DEV__) {
      console.error(
        'unregisterInput must be called with a host component. Passing a react tag is deprecated.',
      );
    }
    return;
  }
  inputs.delete(textField);
}

function isTextInput(textField) {
  if (typeof textField === 'number') {
    if (__DEV__) {
      console.error(
        'isTextInput must be called with a host component. Passing a react tag is deprecated.',
      );
    }
    return false;
  }
  return inputs.has(textField);
}

const TextInputState = {
  currentlyFocusedInput,
  focusInput,
  blurInput,

  currentlyFocusedField,
  focusField,
  blurField,
  focusTextInput,
  blurTextInput,
  registerInput,
  unregisterInput,
  isTextInput,
};

module.exports = TextInputState;
module.exports.default = TextInputState;
