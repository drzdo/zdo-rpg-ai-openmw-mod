# ZdoRpg OpenMW Mod

## OpenMW Lua UI

- For simple HUD text, use `ui.TYPE.Text` directly as the root widget. Do NOT wrap it in `ui.TYPE.Flex` with `ui.content` children — the element will be created without errors but won't render.
- `ui.content()` cannot be called at module scope (script load time). UI elements must be created inside an engine handler (e.g. `onFrame`).
- To update text without recreating the element: `element.layout.props.text = newText` then `element:update()`.
