# Components

This directory contains the frontend MVP panel components:

- `app-providers.tsx` wires shared client-side providers such as TanStack Query.
- `control-panel.tsx` contains the authenticated operator panel for dashboard data,
  node registration commands, VM actions, task logs, images, plans, and IP pools.

Keep reusable UI here when it is shared by the panel. Keep request and auth helpers
in `frontend/lib/` so component code stays focused on state and rendering.
