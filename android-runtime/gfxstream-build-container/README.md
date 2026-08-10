# gfxstream build container

Collider adds this thin entrypoint to the shared, pinned native dependency
image. Both Linux architecture lanes use the resulting image while retaining
independent build and compiler-cache workspaces.

The entrypoint owns only gfxstream's mount contract. Changes to unrelated
native component entrypoints do not invalidate gfxstream compilation, and
gfxstream entrypoint changes do not invalidate those components.
