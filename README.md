# sing-box-for-apple

Experimental iOS/macOS/tvOS client for sing-box, the universal proxy platform.

## Documentation

[SFI](https://sing-box.sagernet.org/installation/clients/sfi/) | [SFM](https://sing-box.sagernet.org/installation/clients/sfm/)

This tree builds the Apple client against an MITM-enabled
`Libbox.xcframework`: sing-box `v1.15.0-alpha.7` plus the Surge MITM port
and its HTTP/1.1, HTTP/2, rewrite-pipeline, Script Hub, body-codec and
configuration-safety fixes (`Patches/mitm-1.15.patch`).

- Build the MITM core: `./Scripts/build-mitm-libbox.sh`
- Generate a private MITM CA and ready-to-import profile: `./Scripts/generate-mitm-ca.sh`
- Build a signed IPA with the local signing assets: `./Scripts/build-ipa.sh`
- Chinese usage guide: [`docs/MITM_GUIDE.zh-CN.md`](docs/MITM_GUIDE.zh-CN.md)

## License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```
