# Embedded process symbols

458 static SVG symbols from the `Proc. Engineering` folder of
[FUXA-SVG-Widgets](https://github.com/frangoteam/FUXA-SVG-Widgets/tree/70e7c4a656d111c0428c77eb4b0409fc3670b8d5),
pinned at `70e7c4a656d111c0428c77eb4b0409fc3670b8d5`.

The upstream MIT license is preserved verbatim in `LICENSE-FUXA.txt` and shown
in the application license screen. MIT permits commercial use with preservation
of its copyright and license notice. The catalog records each original path,
original SHA-256 and modified asset SHA-256.

These are modified static geometry assets: scripts, event handlers, foreign
elements, external references and empty definitions were removed; supported
inline presentation styles were normalized. Embedded scripts are never executed.
Other upstream folders are excluded, including `dynamicSVG` files bearing Opto22
notices. No blanket licensing assertion is made for excluded assets.

To reproduce, extract the archive for that exact revision and run:

```sh
python ci/vendor_process_symbols.py --source /path/to/FUXA-SVG-Widgets-70e7c4a656d111c0428c77eb4b0409fc3670b8d5
python ci/process_symbol_geometry.py
python -m unittest discover -s ci -p test_process_symbols.py
```

These commands run from the repository root. Builds use committed assets without
downloading the source repository. User-added PNG/JPEG images remain the user's
own resources; their rights are separate from this symbol library.

`ci/process_symbol_geometry.py` also reads the four original example SVGs and
generates `app/lib/features/process/symbol_sizes.dart`. Its `--check` mode and the
integrity tests reject stale geometry. Flutter shares one contained viewport and
rotation transform for drawing and pipe anchors. Reviewed example contacts live
in `symbol_geometry.dart`; imported symbols use viewport edges until individual
physical ports are reviewed. Original SVG bytes and upstream provenance remain
unchanged by this connection fix.
