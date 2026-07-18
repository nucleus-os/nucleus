import React from 'react';
import { View, type HostInstance, type ViewProps } from 'react-native';

export type EdgeInsets = {
  top: number;
  right: number;
  bottom: number;
  left: number;
};

const ZERO_INSETS: EdgeInsets = {
  top: 0,
  right: 0,
  bottom: 0,
  left: 0,
};

export function useSafeAreaInsets(): EdgeInsets {
  return ZERO_INSETS;
}

export const SafeAreaProvider = ({
  children,
}: {
  children?: React.ReactNode;
}) => <>{children}</>;

export const SafeAreaView = React.forwardRef<HostInstance, ViewProps>(
  ({ children, ...props }, ref) => {
    return (
      <View ref={ref} {...props}>
        {children}
      </View>
    );
  }
);

SafeAreaView.displayName = 'SafeAreaView';

export default {
  useSafeAreaInsets,
  SafeAreaProvider,
  SafeAreaView,
};
