# Windows Version Resource Verification Guide

This guide describes how to verify that version information is correctly written
into exported `.exe` files after the FIXED_FILE_INFO and StringTable patches.


## What Was Fixed

1. **FIXED_FILE_INFO binary fields** — `FileVersionMS`, `FileVersionLS`,
   `ProductVersionMS`, `ProductVersionLS` are now patched with values derived
   from `build.lua` `version`. Windows Explorer reads these fields for the
   Details tab in file properties.

2. **String table entries** — `FileDescription`, `FileVersion`, `ProductVersion`
   are still written. `CompanyName` and `ProductName` are now also written.

3. **Size validation** — if the new string table data exceeds the original
   resource size, a warning is logged and the data is truncated instead of
   silently corrupting the exe.

4. **FIXED_FILE_INFO signature check** — before patching, the code verifies the
   `0xFEEF04BD` signature. If the signature doesn't match (e.g. unusual PE
   layout), the binary patch is skipped with a warning, and the string table
   replacement still proceeds.


## Prerequisites

- A Windows machine (or Wine) to inspect file properties
- The `example-project/` with its `build.lua` (version `1.0.0`, name
  `ExampleGame`, developer `ellraiser`)
- Or your own project with known version values


## Step-by-Step Verification

### 1. Build the Project

Run love-build on the example-project. Ensure `platforms = {'windows'}` is set
in `build.lua`. This will produce a `.zip` containing the fused exe.

### 2. Extract and Inspect File Properties (GUI)

On Windows:

1. Right-click the output `.exe` file
2. Select **Properties** → **Details** tab
3. Check these fields match your `build.lua` config:

| Field              | Expected Value (example-project) | Source                   |
|--------------------|----------------------------------|--------------------------|
| File version       | 1.0.0.0                         | FIXED_FILE_INFO binary   |
| Product version    | 1.0.0.0                         | FIXED_FILE_INFO binary   |
| File description   | ExampleGame by ellraiser         | StringTable              |
| Product name       | ExampleGame                      | StringTable              |
| Company name       | ellraiser                        | StringTable              |

If "File version" and "Product version" show `11.5.0.0` (the LÖVE version),
the FIXED_FILE_INFO patch was not applied — check the build log for
signature mismatch warnings.

### 3. Inspect with PowerShell

```powershell
# Get version info from the exe
(Get-Item "ExampleGame.exe").VersionInfo | Format-List *
```

Check these properties:

```
FileVersion     : 1.0.0.0       # from FIXED_FILE_INFO
ProductVersion  : 1.0.0.0       # from FIXED_FILE_INFO
FileDescription : ExampleGame by ellraiser
CompanyName     : ellraiser
ProductName     : ExampleGame
```

### 4. Inspect with Resource Hacker (deep check)

For a binary-level check:

1. Open the exe in [Resource Hacker](http://www.angusj.com/resourcehacker/)
2. Navigate to **Version Info** → **1** → **1033**
3. Verify:
   - `FILEVERSION` shows `1,0,0,0` (binary FIXED_FILE_INFO)
   - `PRODUCTVERSION` shows `1,0,0,0` (binary FIXED_FILE_INFO)
   - `VALUE "FileDescription"` shows `ExampleGame by ellraiser`
   - `VALUE "FileVersion"` shows `1.0.0`
   - `VALUE "ProductVersion"` shows `1.0.0`
   - `VALUE "CompanyName"` shows `ellraiser`
   - `VALUE "ProductName"` shows `ExampleGame`

### 5. Check Build Logs

In the build output folder, open `build.log` and look for:

```
love.exedit >         version parts:    1    0    0    0
love.exedit >         String    FileDescription    32
love.exedit >         String    FileVersion        10
love.exedit >         String    ProductVersion     10
love.exedit >         String    CompanyName        16
love.exedit >         String    ProductName        22
love.exedit >         string table:    <N>    bytes, padding:    <M>
love.exedit >         FIXED_FILE_INFO patched:    1.0.0.0
love.exedit >         version info written to exe successfully
```

- **padding** should be a positive number (space remaining after new entries)
- If padding is 0 and you see the ERROR line about exceeding size, the config
  values are too long for the available resource space
- If you see `WARN: FIXED_FILE_INFO signature mismatch`, the binary fields
  were not patched (the string table was still updated)

### 6. Verify 32-bit and 64-bit Builds

If `use32bit = true` is set in `build.lua`, both 64-bit and 32-bit exes are
produced. Verify both:

- `{name}-windows.zip` — 64-bit (PE32+, magic `0x20B`)
- `{name}-windows32.zip` — 32-bit (PE32, magic `0x10B`)

The version resource patching uses the same code path for both, since the
resource section structure is identical regardless of PE32 vs PE32+. The
PE32/PE32+ differences only affect the optional header parsing (image base,
stack/heap sizes), which happens before resource processing.

### 7. Cross-Check: Version Format Edge Cases

Test with different version strings in `build.lua`:

| `version` value | Expected FileVersion  | Notes                    |
|-----------------|----------------------|--------------------------|
| `"1.0.0"`       | 1.0.0.0              | Standard 3-part          |
| `"2.1"`         | 2.1.0.0              | Two-part (patch=0)       |
| `"3.0.1.7"`     | 3.0.1.7              | Full 4-part              |
| `"12.0"`        | 12.0.0.0             | LÖVE-style version       |
| `"1.0"`         | 1.0.0.0              | Minimal                  |

In all cases, the string table `FileVersion` should show the original string
(e.g., `"2.1"`), while the binary FIXED_FILE_INFO should show the 4-part
numeric version.


## Known Limitations

- The version resource is patched in-place within the existing resource section.
  The new string table data must fit within the original StringTable size. Very
  long `name`, `developer`, or `version` values may exceed available space.
- Only the first VERSION resource entry (first language) is modified.
- The COFF checksum is not recalculated after modification. Windows typically
  ignores checksum mismatches for user-mode executables.
- If the VS_VERSIONINFO structure in the source exe has an unusual layout
  (non-standard padding, missing FIXED_FILE_INFO), the signature check will
  fail and the binary fields will not be patched.
