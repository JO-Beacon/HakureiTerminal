# Third-Party Licenses

HakureiTerminal is licensed under the Apache License 2.0. The HakureiTerminal source tree, APK, desktop bundle, installer, and default assets do not contain GensokyoAI source code, binaries, wheels, characters, scenes, configuration, documentation, or other Runtime payloads.

## GensokyoAI

- Role: independently deployed sole authority for executable characters, sessions, messages, context, memory, scenes, tools, timers, and generation state, used through its public HTTP/WebSocket Runtime API
- Integrated protocol target: independently deployed `2026.7.14.0`
- Distribution model: not distributed, installed, downloaded, updated, or started by HakureiTerminal
- `2026.7.14.0` license: Apache License 2.0
- Historical version fact: `2026.5.13.0` was licensed under the MIT License; it is not the current external protocol target
- Copyright: Copyright (c) 2026 Patchouli-CN

Users and operators obtain and deploy GensokyoAI separately and are responsible for reviewing the source, license, integrity, deployment, Provider configuration, and network security of the version they operate. HakureiTerminal's acknowledgement of interoperability does not redistribute GensokyoAI and does not replace its upstream license or notices. GensokyoAI changed from MIT to Apache-2.0 after `2026.5.13.0`; anyone independently redistributing a release must preserve the license applicable to that release. The historical MIT text retained for attribution and version history follows.

HakureiTerminal is a dedicated frontend and does not provide an alternative built-in execution path. This product role does not make GensokyoAI part of HakureiTerminal's distribution.

```text
MIT License

Copyright (c) 2026 Patchouli-CN

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Source Han Sans

- Bundled files: `assets/fonts/SourceHanSansSC-Regular.otf`, `SourceHanSansSC-Medium.otf`, and `SourceHanSansSC-Bold.otf`
- Role: Default HakureiTerminal user-interface font
- Upstream name: Source Han Sans Simplified Chinese
- Copyright: Copyright 2014-2025 Adobe (http://www.adobe.com/)
- Reserved Font Name: `Source`
- License: SIL Open Font License 1.1
- Full license text: `assets/licenses/SourceHanSans-OFL-1.1.txt`

The font files are redistributed unmodified and are not sold separately. The font software remains licensed under the SIL Open Font License 1.1; HakureiTerminal's Apache License 2.0 does not replace or alter the font license.
