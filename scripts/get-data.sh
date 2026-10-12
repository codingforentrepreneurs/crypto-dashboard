#!/usr/bin/env bash
# Download the Twelve Data crypto sample used by the Tiger Data tutorial.
set -euo pipefail
mkdir -p "$(dirname "$0")/../data"
cd "$(dirname "$0")/../data"
[ -f tutorial_sample_tick.csv ] && { echo "data/ already has the CSVs"; exit 0; }
curl -fSL -o crypto_sample.zip https://assets.timescale.com/docs/downloads/candlestick/crypto_sample.zip
unzip -o crypto_sample.zip
rm crypto_sample.zip
wc -l tutorial_sample_tick.csv tutorial_sample_assets.csv
