/**
 * Nucleus TextInput implementation (Phase 1).
 *
 * This is intentionally minimal: it renders a host component named `TextInput`
 * and participates in TextInputState focus registration. Phase 2+ will add
 * full RN parity for eventCount/selection synchronization.
 */
'use strict';

const React = require('react');
const {useEffect, useRef, useState} = React;

const TextInputState = require('./TextInputState.nucleus').default ?? require('./TextInputState.nucleus');
const NativeModule = require('./NucleusTextInputNativeComponent.nucleus');
const NucleusTextInputNativeComponent = NativeModule.default ?? NativeModule;
const NucleusTextInputCommands = NativeModule.Commands;

function clampInt(n, min, max) {
  const v = typeof n === 'number' ? n : 0;
  if (Number.isNaN(v)) return min;
  return Math.max(min, Math.min(max, v));
}

function normalizeSelection(sel, text) {
  if (!sel || typeof sel !== 'object') return null;
  const len = typeof text === 'string' ? text.length : 0;
  const start = clampInt(sel.start, 0, len);
  const end = clampInt(sel.end ?? sel.start, 0, len);
  return {start, end};
}

function selectionFromEvent(e) {
  const ne = e?.nativeEvent;
  if (!ne) return null;
  if (ne.selection && typeof ne.selection === 'object') {
    const start = ne.selection.start;
    const end = ne.selection.end ?? start;
    if (typeof start === 'number') return {start, end};
  }
  if (ne.selectionRange && typeof ne.selectionRange === 'object') {
    const loc = ne.selectionRange.location;
    const len = ne.selectionRange.length ?? 0;
    if (typeof loc === 'number' && typeof len === 'number') {
      return {start: loc, end: loc + len};
    }
  }
  if (typeof ne.selectionStart === 'number') {
    const start = ne.selectionStart;
    const end = typeof ne.selectionEnd === 'number' ? ne.selectionEnd : start;
    return {start, end};
  }
  return null;
}

function TextInput(props, forwardedRef) {
  const innerRef = useRef(null);
  const [mostRecentEventCountState, setMostRecentEventCountState] = useState(
    props.mostRecentEventCount ?? 0,
  );
  const lastNativeTextRef = useRef(typeof props.value === 'string' ? props.value : '');
  const lastNativeSelectionRef = useRef(null);

  const setRef = (node) => {
    innerRef.current = node;
    if (typeof forwardedRef === 'function') {
      forwardedRef(node);
    } else if (forwardedRef && typeof forwardedRef === 'object') {
      forwardedRef.current = node;
    }
  };

  // Register with TextInputState so global focus helpers work.
  useEffect(() => {
    const node = innerRef.current;
    if (node) {
      TextInputState.registerInput(node);
      return () => TextInputState.unregisterInput(node);
    }
    return undefined;
  }, []);

  // Provide a stable default for `text` prop.
  const text =
    typeof props.value === 'string'
      ? props.value
      : typeof props.defaultValue === 'string'
        ? props.defaultValue
        : props.text;

  const onChange = (e) => {
    const nextEventCount = e?.nativeEvent?.eventCount;
    if (typeof nextEventCount === 'number') {
      setMostRecentEventCountState(nextEventCount);
    }

    const nextText = e?.nativeEvent?.text;
    if (typeof nextText === 'string') {
      lastNativeTextRef.current = nextText;
    }
    const sel = selectionFromEvent(e);
    if (sel) {
      lastNativeSelectionRef.current = sel;
    }

    props.onChange?.(e);

    if (typeof nextText === 'string') {
      props.onChangeText?.(nextText);
    }
  };

  const onSelectionChange = (e) => {
    const sel = selectionFromEvent(e);
    if (sel) {
      lastNativeSelectionRef.current = sel;
    }
    props.onSelectionChange?.(e);
  };

  const onFocus = (e) => {
    const node = innerRef.current;
    if (node) {
      TextInputState.focusInput(node);
    }
    props.onFocus?.(e);
  };

  const onBlur = (e) => {
    const node = innerRef.current;
    if (node) {
      TextInputState.blurInput(node);
    }
    props.onBlur?.(e);
  };

  const mostRecentEventCount = props.mostRecentEventCount ?? mostRecentEventCountState;

  // Controlled input reconciliation:
  // If native text diverges from `props.value`, restore JS value via `setTextAndSelection`.
  useEffect(() => {
    if (typeof props.value !== 'string') {
      return;
    }
    const node = innerRef.current;
    if (!node) {
      return;
    }

    const desiredText = props.value;
    const nativeText = lastNativeTextRef.current;

    const selectionProp = normalizeSelection(props.selection, desiredText);
    const fallbackSelection =
      lastNativeSelectionRef.current ??
      selectionProp ??
      ({start: desiredText.length, end: desiredText.length});
    const desiredSelection = normalizeSelection(fallbackSelection, desiredText) ?? {
      start: desiredText.length,
      end: desiredText.length,
    };

    const shouldUpdateText = desiredText !== nativeText;
    const shouldUpdateSelection =
      selectionProp != null &&
      (lastNativeSelectionRef.current == null ||
        selectionProp.start !== lastNativeSelectionRef.current.start ||
        selectionProp.end !== lastNativeSelectionRef.current.end);

    if (!shouldUpdateText && !shouldUpdateSelection) {
      return;
    }

    NucleusTextInputCommands.setTextAndSelection(
      node,
      mostRecentEventCount,
      shouldUpdateText ? desiredText : null,
      desiredSelection.start,
      desiredSelection.end,
    );

    // Optimistically update mirrors to avoid repeated commands while native catches up.
    if (shouldUpdateText) {
      lastNativeTextRef.current = desiredText;
    }
    lastNativeSelectionRef.current = desiredSelection;
  }, [mostRecentEventCount, props.value, props.selection?.start, props.selection?.end]);

  return (
    <NucleusTextInputNativeComponent
      {...props}
      ref={setRef}
      text={text}
      // Ensure these exist so the native side can keep parity later.
      mostRecentEventCount={mostRecentEventCount}
      onChange={onChange}
      onSelectionChange={onSelectionChange}
      onFocus={onFocus}
      onBlur={onBlur}
    />
  );
}

const Forwarded = React.forwardRef(TextInput);

// Keep upstream-ish static property for callers that use TextInput.State.
// $FlowFixMe[prop-missing]
Forwarded.State = TextInputState;

// $FlowFixMe[prop-missing]
Forwarded.Commands = NucleusTextInputCommands;

module.exports = Forwarded;
module.exports.default = Forwarded;
