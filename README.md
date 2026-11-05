# H3 Seasons

Build a global monthly RGB map from NASA's MCD43C4 2025 HDF files. This run uses one product file dated on the first day of each month; it does not combine years. MCD43C4 values use a 16-day Terra/Aqua composite. Julia reads MODIS bands 1, 4, and 3, then samples one pixel at each land H3 cell centre. If that pixel has fill data, Julia uses the nearest valid pixel whose centre is closer to that H3 centre than to any adjacent H3 centre. Julia saves raw sampling checkpoints and H3-MON Arrow files. A restart reuses the files on disk.

Julia performs the raster processing locally after it downloads the NASA files.

## NASA account and licence terms

1. Create an [Earthdata Login account](https://urs.earthdata.nasa.gov/), or sign in to your account.
2. Open the [MCD43C4 product page](https://ladsweb.modaps.eosdis.nasa.gov/missions-and-measurements/products/MCD43C4) and follow its data-access link to LAADS DAAC.
3. While signed in, open the [2025 MCD43C4 archive](https://ladsweb.modaps.eosdis.nasa.gov/archive/allData/61/MCD43C4/2025/). If Earthdata sends you to a `/profiles/licenses/` page, read the displayed terms and accept them. Return to the archive and retry the download.
4. Create an Earthdata download token in your [Earthdata Login profile](https://urs.earthdata.nasa.gov/profile). Add it to `.env`:

   ```text
   EARTH_DATA_BEARER=your-token
   ```

Keep `.env` private. The repository ignores this file. The download script also reads the token from the shell environment.

NASA links:

- [MCD43C4 V061 dataset information](https://www.earthdata.nasa.gov/data/catalog/lpcloud-mcd43c4-061)
- [LAADS MCD43C4 product page](https://ladsweb.modaps.eosdis.nasa.gov/missions-and-measurements/products/MCD43C4)
- [LAADS download instructions](https://ladsweb.modaps.eosdis.nasa.gov/learn/download-files-using-edl-tokens/)
- [Earthdata Login token guide](https://urs.earthdata.nasa.gov/documentation/for_users/user_token)

## Install and run

Use Julia 1.10 or newer. Install the Julia dependencies:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Generate the Natural Earth land-cell list:

```sh
julia --project=. bin/generate_cells.jl
```

Download the 12 files dated on the first day of each month:

```sh
julia --project=. bin/download_nasa_data.jl
```

To check one month first, add its month number to either command:

```sh
julia --project=. bin/download_nasa_data.jl 1
julia --project=. bin/build_nasa_outputs.jl 1
```

Build all monthly Arrow files:

```sh
julia --project=. bin/build_nasa_outputs.jl
```

The first download is about 1.2 GB. The script skips valid files that already exist. Sampling checkpoints are stored in `cache/nasa_mcd43c4_2025/global_land_r4/`.

## H3-MON files

The build writes these files to `out/planet_mcd43c4_2025/`:

- `planet_mcd43c4_2025_month_01.arrow` through `planet_mcd43c4_2025_month_12.arrow`
- `planet_mcd43c4_2025_month_01.json`, with the month slider and change URL

Copy them to H3-MON's data directory:

```sh
cp out/planet_mcd43c4_2025/*.arrow ~/projects/H3-MON/www/data/
cp out/planet_mcd43c4_2025/*.json ~/projects/H3-MON/www/data/
```

Open `http://localhost:1983/?data=planet_mcd43c4_2025_month_01.arrow` in H3-MON.

Each Arrow row contains split H3 index fields, direct `r`, `g`, `b`, `a` channels, a `fallback` flag, and source-pixel offsets. The output includes cells with valid RGB samples. The Natural Earth 1:50m mask keeps H3 centres on land.

## Checks

Run the tests with:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```
