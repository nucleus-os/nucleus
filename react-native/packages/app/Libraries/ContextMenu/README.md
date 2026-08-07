# Context Menu

Headless context menu events with an optional default React UI.

## Usage

```tsx
import { ContextMenu } from '@nucleus-os/app';

const contextMenuConfig = {
  items: [
    { type: 'item', id: 'copy', title: 'Copy', action: { type: 'copy' } },
    { type: 'separator' },
    {
      type: 'item',
      id: 'search',
      title: 'Search with Google',
      action: {
        type: 'openUrlTemplate',
        template: 'https://www.google.com/search?q={query}',
      },
    },
  ],
};

export function App() {
  return <ContextMenu config={contextMenuConfig} />;
}
```

### Custom UI

```tsx
import { ContextMenu } from '@nucleus-os/app';

export function App() {
  return (
    <ContextMenu
      config={{ items: [], enabled: true }}
      renderMenu={({ request, close }) => (
        <MyContextMenu x={request.x} y={request.y} onDismiss={close} />
      )}
    />
  );
}
```

## Notes

- The native layer only emits events; React renders the menu UI.
- Dev builds only: use `setDevToolsItemEnabled(true)` to append the built-in "Open DevTools" item.
- Multi-window: secondary windows created via `@nucleus-os/window` automatically include the default context menu overlay and will render using the last config set via `setContextMenu`/`ContextMenuConfigurator`/`<ContextMenu />`. For fully custom context menu UI in a secondary window, render `<ContextMenu />` (or your own listener) inside that window’s component tree.
