"""
Convert MobileFaceNet ONNX model to CoreML (.mlpackage) for face recognition.

Run on your Mac:
    pip install coremltools onnx
    python convert_model.py

This will produce MobileFaceNet.mlpackage — drag it into your Xcode project.
"""

import urllib.request
import os
import coremltools as ct
import numpy as np

MODEL_URL = "https://github.com/onnx/models/raw/main/validated/vision/body_analysis/arcface/model/arcfaceresnet100-8.onnx"
ONNX_PATH = "arcface_mobilefacenet.onnx"
OUTPUT_PATH = "MobileFaceNet.mlpackage"

# Try multiple known sources for a face embedding model
MODEL_URLS = [
    # InsightFace buffalo_l w600k_r50 (small, reliable)
    ("https://github.com/deepinsight/insightface/raw/master/python-package/insightface/models/buffalo_l/w600k_r50.onnx", "w600k_r50.onnx"),
]

def download_model():
    """Download a pre-trained face embedding ONNX model."""
    # First check if user already has an ONNX file locally
    local_files = [f for f in os.listdir('.') if f.endswith('.onnx')]
    if local_files:
        print(f"Found local ONNX file: {local_files[0]}")
        return local_files[0]

    print("No local .onnx file found.")
    print()
    print("Please download a MobileFaceNet ONNX model manually:")
    print()
    print("Option 1 - InsightFace (recommended):")
    print("  pip install insightface")
    print("  python -c \"")
    print("  import insightface")
    print("  from insightface.app import FaceAnalysis")
    print("  app = FaceAnalysis(name='buffalo_sc', providers=['CPUExecutionProvider'])")
    print("  app.prepare(ctx_id=-1)")
    print("  print('Model downloaded to ~/.insightface/models/buffalo_sc/')")
    print("  \"")
    print("  Then copy the recognition model .onnx file here.")
    print()
    print("Option 2 - Direct download:")
    print("  Download mobilefacenet from:")
    print("  https://github.com/onnx/models/tree/main/validated/vision/body_analysis/arcface")
    print("  Place the .onnx file in this directory.")
    print()
    print("Option 3 - Use the bundled script:")
    print("  python download_mobilefacenet.py")
    print()
    return None


def convert_to_coreml(onnx_path):
    """Convert ONNX face embedding model to CoreML."""
    import onnx

    print(f"Loading ONNX model: {onnx_path}")
    onnx_model = onnx.load(onnx_path)

    # Inspect input shape
    input_info = onnx_model.graph.input[0]
    input_shape = [d.dim_value for d in input_info.type.tensor_type.shape.dim]
    print(f"Input shape: {input_shape}")

    # Determine image size (typically [1, 3, 112, 112])
    if len(input_shape) == 4:
        img_size = input_shape[2]  # height
    else:
        img_size = 112
    print(f"Image size: {img_size}x{img_size}")

    # Inspect output shape
    output_info = onnx_model.graph.output[0]
    output_name = output_info.name
    print(f"Output name: {output_name}")

    # Fix dynamic batch dimension (0 -> 1) in the ONNX model itself
    if input_shape[0] == 0:
        input_info.type.tensor_type.shape.dim[0].dim_value = 1
        input_shape[0] = 1
        print(f"Fixed input shape: {input_shape}")

    # Also fix output dynamic dims if present
    for out in onnx_model.graph.output:
        for dim in out.type.tensor_type.shape.dim:
            if dim.dim_value == 0:
                dim.dim_value = 1

    # Save fixed model to a temp file for conversion
    fixed_path = "fixed_" + onnx_path
    onnx.save(onnx_model, fixed_path)
    print(f"Saved fixed ONNX model: {fixed_path}")

    print("Converting to CoreML...")
    # Load as onnx model object to avoid source detection issues
    import onnx as onnx_lib
    onnx_model_fixed = onnx_lib.load(fixed_path)

    mlmodel = ct.convert(
        onnx_model_fixed,
        inputs=[
            ct.ImageType(
                name=input_info.name,
                shape=tuple(input_shape),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )

    # Clean up temp file
    os.remove(fixed_path)

    # Set model metadata
    mlmodel.author = "CameraBridge"
    mlmodel.short_description = "MobileFaceNet face embedding model (112x112 RGB -> 128/512-d vector)"
    mlmodel.input_description["image"] = "Face image (cropped and aligned)"

    mlmodel.save(OUTPUT_PATH)
    print(f"\nSaved: {OUTPUT_PATH}")
    print(f"\nNext steps:")
    print(f"  1. Drag {OUTPUT_PATH} into your Xcode project (CameraBridge target)")
    print(f"  2. Xcode will auto-generate a Swift class called 'MobileFaceNet'")
    print(f"  3. Build and run!")


if __name__ == "__main__":
    onnx_path = download_model()
    if onnx_path:
        convert_to_coreml(onnx_path)
    else:
        print("\nOnce you have the .onnx file, re-run this script.")
