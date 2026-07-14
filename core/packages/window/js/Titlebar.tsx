import React from 'react';
import { StyleSheet, View } from 'react-native';
import type { ViewProps } from 'react-native';

import { useTitlebarMetrics } from './useTitlebarMetrics';

export interface TitlebarProps extends ViewProps {
  height?: number;
  leftInset?: number;
  windowId?: number;
}

export function Titlebar({
  height,
  leftInset,
  windowId,
  style,
  ...props
}: TitlebarProps) {
  const metrics = useTitlebarMetrics(windowId);
  const resolvedHeight = height ?? metrics.height;
  const resolvedLeftInset = leftInset ?? metrics.leftInset;

  return (
    <View
      {...props}
      style={[
        styles.titlebar,
        resolvedHeight ? { height: resolvedHeight } : null,
        resolvedLeftInset ? { paddingLeft: resolvedLeftInset } : null,
        style,
      ]}
    />
  );
}

const styles = StyleSheet.create({
  titlebar: {
    flexDirection: 'row',
    alignItems: 'center',
    width: '100%',
  },
});
