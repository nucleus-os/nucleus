# Window Management API

Multi-window support for NUCLEUS. Create and manage multiple native windows, each with its own React surface.

## API Levels

### 1. Low-Level TurboModule API

Direct access to native window management functions.

```tsx
import { WindowManager } from '@nucleus-os/window';

// Create a window
const windowId = await WindowManager.createWindow(800, 600, 1.0, 1.0);

// Create a React surface on the window
const surfaceId = await WindowManager.createSurface(
  windowId,
  'MyApp',
  { initialProps: {} }
);

// Clean up
WindowManager.stopSurface(surfaceId);
```

### 2. React Hook API

Declarative window management with React hooks.

```tsx
import { useWindow } from '@nucleus-os/window';

function MyComponent() {
  const { windowId, isCreating, error } = useWindow({
    width: 800,
    height: 600,
  });

  if (isCreating) return <Text>Creating window...</Text>;
  if (error) return <Text>Error: {error.message}</Text>;

  return <Text>Window created: {windowId}</Text>;
}
```

### 3. React Component API

Render content in a separate window using a React component.

```tsx
import { Window } from '@nucleus-os/window';

function App() {
  return (
    <>
      <View><Text>Main Window</Text></View>

      <Window width={600} height={400} title="Second Window">
        <View><Text>This renders in a separate window!</Text></View>
      </Window>
    </>
  );
}
```

## Features

- **Independent React Trees**: Each window has its own React surface and component tree
- **Separate State Management**: State is independent per window
- **Full React Native API**: All React Native components and APIs work in secondary windows
- **Native Window Controls**: Resize, move, and manage windows using native OS controls
- **Automatic Cleanup**: Windows and surfaces are automatically cleaned up when components unmount
- **Custom Chrome**: Optional React-rendered titlebar + window controls on desktop

## Types

All TypeScript types are exported from the main package:

```tsx
import type {
  WindowManagerSpec,
  UseWindowOptions,
  UseWindowResult,
  WindowProps,
} from '@nucleus-os/window';
```

## Custom Titlebar / Window Controls

NUCLEUS can hide the native titlebar and let React render custom chrome. On macOS
the native traffic lights remain, while Windows/Linux can use custom controls.

```tsx
import { Titlebar, useTitlebarMetrics } from '@nucleus-os/window';

function AppChrome() {
  const { height, leftInset } = useTitlebarMetrics();
  return (
    <Titlebar height={height} leftInset={leftInset}>
      <MyMenuBar />
    </Titlebar>
  );
}
```

Enable custom chrome at window creation time:

```tsx
import { Window } from '@nucleus-os/window';

<Window
  titlebar={{ appearsTransparent: true }}
  windowDecorations="client"
  component={SettingsWindow}
/>
```

Root window (rna.config.*):

```ts
export default {
  window: {
    titlebar: { appearsTransparent: true },
    windowDecorations: 'client',
  },
};
```
