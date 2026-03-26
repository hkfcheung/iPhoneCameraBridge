"""
Download MobileFaceNet ONNX model using InsightFace package.

Run on your Mac:
    pip install insightface onnxruntime
    python download_mobilefacenet.py

This downloads the buffalo_sc model pack which includes a lightweight
face recognition model suitable for mobile use.
"""

import shutil
import os

def main():
    try:
        from insightface.app import FaceAnalysis
    except ImportError:
        print("Install insightface first:")
        print("  pip install insightface onnxruntime")
        return

    print("Downloading InsightFace buffalo_sc model pack...")
    app = FaceAnalysis(name="buffalo_sc", providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1)

    # Find the recognition model
    home = os.path.expanduser("~")
    model_dir = os.path.join(home, ".insightface", "models", "buffalo_sc")

    if not os.path.isdir(model_dir):
        print(f"Model directory not found: {model_dir}")
        return

    # The recognition model is typically named w600k_mbf.onnx
    for fname in os.listdir(model_dir):
        if fname.endswith(".onnx"):
            src = os.path.join(model_dir, fname)
            # Check if it's the recognition model (not detection)
            size_mb = os.path.getsize(src) / (1024 * 1024)
            print(f"  Found: {fname} ({size_mb:.1f} MB)")
            if "mbf" in fname.lower() or size_mb > 10:
                dst = os.path.join(os.path.dirname(__file__), fname)
                shutil.copy2(src, dst)
                print(f"  -> Copied to: {dst}")
                print(f"\nNow run: python convert_model.py")
                return

    # Fallback: copy all .onnx files and let user pick
    print("\nCouldn't auto-detect recognition model. Available files:")
    for fname in os.listdir(model_dir):
        if fname.endswith(".onnx"):
            print(f"  {fname}")
    print(f"\nCopy the recognition .onnx file to: {os.path.dirname(__file__)}")
    print("Then run: python convert_model.py")


if __name__ == "__main__":
    main()
