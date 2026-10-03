#!/bin/bash
# Download Whisper model from Hugging Face
set -euo pipefail

MODEL_NAME="${1:-small.en}"
MODEL_FILE="ggml-${MODEL_NAME}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_FILE}"

# App stores models alongside settings in ~/.WhisperDictation
MODELS_DIR="$HOME/.WhisperDictation/Models"
mkdir -p "$MODELS_DIR"

DEST="$MODELS_DIR/$MODEL_FILE"

if [ -f "$DEST" ]; then
    echo "Model already exists: $DEST"
    exit 0
fi

echo "==> Downloading $MODEL_FILE..."
echo "    URL: $MODEL_URL"
echo "    Destination: $DEST"
echo ""

curl -L --progress-bar -o "$DEST" "$MODEL_URL"

SIZE=$(ls -lh "$DEST" | awk '{print $5}')
echo ""
echo "==> Downloaded $MODEL_FILE ($SIZE) to $DEST"
