"""
Convert MobileFaceNet ONNX model to CoreML (.mlpackage) for face recognition.

Run on your Mac:
    pip install coremltools onnx onnx2torch torch numpy
    python convert_model.py

This will produce MobileFaceNet.mlpackage — drag it into your Xcode project.
"""

import os
import coremltools as ct
import numpy as np

OUTPUT_PATH = "MobileFaceNet.mlpackage"


def find_onnx_model():
    """Find a local ONNX model file."""
    local_files = [f for f in os.listdir('.') if f.endswith('.onnx') and not f.startswith('fixed_')]
    if local_files:
        print(f"Found local ONNX file: {local_files[0]}")
        return local_files[0]

    print("No local .onnx file found.")
    print("Run: python download_mobilefacenet.py")
    return None


def convert_to_coreml(onnx_path):
    """Convert ONNX face embedding model to CoreML via PyTorch."""
    import onnx
    import torch
    from onnx2torch import convert as onnx_to_torch

    print(f"Loading ONNX model: {onnx_path}")
    onnx_model = onnx.load(onnx_path)

    # Inspect input shape
    input_info = onnx_model.graph.input[0]
    input_shape = [d.dim_value for d in input_info.type.tensor_type.shape.dim]
    print(f"Input shape: {input_shape}")

    # Fix dynamic batch dimension (0 -> 1)
    if input_shape[0] == 0:
        input_shape[0] = 1
        print(f"Fixed input shape: {input_shape}")

    img_size = input_shape[2] if len(input_shape) == 4 else 112
    print(f"Image size: {img_size}x{img_size}")

    # Convert ONNX -> PyTorch
    print("Converting ONNX to PyTorch...")
    torch_model = onnx_to_torch(onnx_path)
    torch_model.eval()

    # Trace the PyTorch model
    print("Tracing PyTorch model...")
    example_input = torch.randn(1, 3, img_size, img_size)
    with torch.no_grad():
        traced_model = torch.jit.trace(torch_model, example_input)

    # Convert PyTorch -> CoreML
    print("Converting PyTorch to CoreML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, img_size, img_size),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
    )

    # Set model metadata
    mlmodel.author = "CameraBridge"
    mlmodel.short_description = f"MobileFaceNet face embedding model ({img_size}x{img_size} RGB -> embedding vector)"
    mlmodel.input_description["image"] = "Face image (cropped and aligned)"

    mlmodel.save(OUTPUT_PATH)
    print(f"\nSaved: {OUTPUT_PATH}")
    print(f"\nNext steps:")
    print(f"  1. Drag {OUTPUT_PATH} into your Xcode project (CameraBridge target)")
    print(f"  2. Xcode will auto-generate a Swift class called 'MobileFaceNet'")
    print(f"  3. Build and run!")


if __name__ == "__main__":
    onnx_path = find_onnx_model()
    if onnx_path:
        convert_to_coreml(onnx_path)
    else:
        print("\nOnce you have the .onnx file, re-run this script.")
