import React, { useEffect } from 'react';

import type { ContextMenuConfig } from './ContextMenuManager';
import { setContextMenu } from './ContextMenuManager';

export function ContextMenuConfigurator({ config }: { config: ContextMenuConfig }) {
  useEffect(() => {
    setContextMenu(config);
  }, [config]);

  return null;
}
