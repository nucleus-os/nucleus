import type {ColorValue, ViewProps} from 'react-native';

import * as React from 'react';
import {Animated, Easing, PanResponder, Pressable, StyleSheet, View} from 'react-native';

type SwitchChangeEvent = {
  nativeEvent: {
    target: number;
    value: boolean;
  };
};

export type SwitchProps = ViewProps & {
  disabled?: boolean | null;
  value?: boolean | null;

  thumbColor?: ColorValue | null;
  trackColor?:
    | {
        false?: ColorValue | null;
        true?: ColorValue | null;
      }
    | null;
  ios_backgroundColor?: ColorValue | null;

  onTintColor?: ColorValue | null;
  thumbTintColor?: ColorValue | null;
  tintColor?: ColorValue | null;

  onChange?: ((event: SwitchChangeEvent) => void | Promise<void>) | null;
  onValueChange?: ((value: boolean) => void | Promise<void>) | null;
};

const DEFAULT_TRACK_FALSE = '#E5E5EA';
const DEFAULT_TRACK_TRUE = '#34C759';
const DEFAULT_THUMB = '#FFFFFF';

const SWITCH_WIDTH = 51;
const SWITCH_HEIGHT = 31;
const SWITCH_PADDING = 2;
const THUMB_DIAMETER = 27;
const THUMB_TRANSLATE_X = SWITCH_WIDTH - SWITCH_PADDING * 2 - THUMB_DIAMETER;

const Switch = React.forwardRef<React.ElementRef<typeof Pressable>, SwitchProps>(
  function Switch(
    {
      accessibilityRole,
      accessibilityState,
      disabled,
      ios_backgroundColor,
      onChange,
      onValueChange,
      onTintColor,
      style,
      thumbColor,
      thumbTintColor,
      tintColor,
      trackColor,
      value,
      ...restProps
    },
    forwardedRef,
  ) {
    const isOn = value === true;
    const isDisabled = disabled === true || accessibilityState?.disabled === true;

    const progress = React.useRef(new Animated.Value(isOn ? 1 : 0)).current;
    const currentProgressRef = React.useRef(isOn ? 1 : 0);
    const dragStartProgressRef = React.useRef(0);
    const draggedRef = React.useRef(false);
    const draggingRef = React.useRef(false);

    React.useEffect(() => {
      const sub = progress.addListener(({value: next}) => {
        currentProgressRef.current = next;
      });
      return () => {
        progress.removeListener(sub);
      };
    }, [progress]);

    React.useEffect(() => {
      if (draggingRef.current) return;
      Animated.timing(progress, {
        toValue: isOn ? 1 : 0,
        duration: 140,
        easing: Easing.out(Easing.quad),
        useNativeDriver: true,
      }).start();
    }, [isOn, progress]);

    const trackFalse = trackColor?.false ?? tintColor ?? ios_backgroundColor ?? DEFAULT_TRACK_FALSE;
    const trackTrue = trackColor?.true ?? onTintColor ?? DEFAULT_TRACK_TRUE;
    const resolvedThumbColor = thumbColor ?? thumbTintColor ?? DEFAULT_THUMB;

    const mergedAccessibilityState = {
      ...(accessibilityState ?? null),
      disabled: isDisabled || undefined,
      checked: isOn,
    };

    const handlePress = () => {
      if (isDisabled) return;
      const next = !isOn;
      void onValueChange?.(next);
      void onChange?.({nativeEvent: {target: 0, value: next}});
    };

    const commitValue = (next: boolean) => {
      if (next === isOn) {
        Animated.timing(progress, {
          toValue: isOn ? 1 : 0,
          duration: 140,
          easing: Easing.out(Easing.quad),
          useNativeDriver: true,
        }).start();
        return;
      }
      handlePress();
    };

    const panResponder = React.useMemo(
      () =>
        PanResponder.create({
          onStartShouldSetPanResponder: () => !isDisabled,
          onMoveShouldSetPanResponder: (_evt, gestureState) =>
            !isDisabled && Math.abs(gestureState.dx) > 2,
          onPanResponderTerminationRequest: () => false,
          onPanResponderGrant: () => {
            draggingRef.current = true;
            draggedRef.current = false;
            dragStartProgressRef.current = currentProgressRef.current;
          },
          onPanResponderMove: (_evt, gestureState) => {
            draggedRef.current = true;
            const delta = gestureState.dx / THUMB_TRANSLATE_X;
            const next = Math.min(1, Math.max(0, dragStartProgressRef.current + delta));
            progress.setValue(next);
          },
          onPanResponderRelease: () => {
            const wasDragged = draggedRef.current;
            draggingRef.current = false;
            draggedRef.current = false;

            const next = wasDragged ? currentProgressRef.current >= 0.5 : !isOn;
            commitValue(next);
          },
          onPanResponderTerminate: () => {
            draggingRef.current = false;
            draggedRef.current = false;
            Animated.timing(progress, {
              toValue: isOn ? 1 : 0,
              duration: 140,
              easing: Easing.out(Easing.quad),
              useNativeDriver: true,
            }).start();
          },
        }),
      [commitValue, isDisabled, isOn, progress],
    );

    return (
      <Pressable
        {...restProps}
        {...panResponder.panHandlers}
        accessibilityRole={accessibilityRole ?? 'switch'}
        accessibilityState={mergedAccessibilityState}
        disabled={isDisabled}
        onPress={handlePress}
        ref={forwardedRef}
        style={[styles.root, isDisabled && styles.disabled, style]}>
        <View
          pointerEvents="none"
          style={[
            styles.track,
            {
              backgroundColor: trackFalse,
            },
          ]}
        />
        <Animated.View
          pointerEvents="none"
          style={[
            styles.track,
            {
              backgroundColor: trackTrue,
              opacity: progress,
            },
          ]}
        />
        <Animated.View
          pointerEvents="none"
          style={[
            styles.thumb,
            {backgroundColor: resolvedThumbColor},
            {
              transform: [
                {
                  translateX: progress.interpolate({
                    inputRange: [0, 1],
                    outputRange: [0, THUMB_TRANSLATE_X],
                  }),
                },
              ],
            },
          ]}
        />
      </Pressable>
    );
  },
);

const styles = StyleSheet.create({
  root: {
    alignSelf: 'flex-start',
    width: SWITCH_WIDTH,
    height: SWITCH_HEIGHT,
    justifyContent: 'center',
    cursor: 'pointer',
  },
  disabled: {
    opacity: 0.5,
  },
  track: {
    position: 'absolute',
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    borderRadius: SWITCH_HEIGHT / 2,
  },
  thumb: {
    position: 'absolute',
    width: THUMB_DIAMETER,
    height: THUMB_DIAMETER,
    borderRadius: THUMB_DIAMETER / 2,
    left: SWITCH_PADDING,
    top: SWITCH_PADDING,
  },
});

export default Switch;
