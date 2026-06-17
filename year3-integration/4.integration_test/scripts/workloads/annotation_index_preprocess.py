"""
MSCOCO 스타일 annotation JSON을 읽어 작은 metadata index 파일을 생성한다.

raw annotation은 dataset-ingest 성격의 large JSON이며, 생성되는 index는
image_id, category_id, caption keyword 기반의 작은 metadata로 학습/검증에서
반복 조회된다. small metadata read / repeated cache 패턴을 가정한다.

Author: 미정 <unknown@example.com>
Created: 2026-05-28
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import time
from collections import defaultdict
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    """annotation index 생성용 실행 인자를 파싱한다.

    Returns:
        argparse.Namespace: 입력/출력 경로와 sample annotation 생성 옵션.
    """
    parser = argparse.ArgumentParser(description="Annotation index preprocessing workload")
    parser.add_argument("--raw-dir", default=os.getenv("RAW_DIR", "/data/raw"))
    parser.add_argument("--annotation-file", default=os.getenv("ANNOTATION_FILE", "annotations.json"))
    parser.add_argument("--index-dir", default=os.getenv("INDEX_DIR", "/data/index"))
    parser.add_argument("--log-dir", default=os.getenv("LOG_DIR", "/data/logs"))
    parser.add_argument("--sample-images", type=int, default=int(os.getenv("SAMPLE_IMAGES", "256")))
    parser.add_argument("--sample-categories", type=int, default=int(os.getenv("SAMPLE_CATEGORIES", "8")))
    parser.add_argument("--annotations-per-image", type=int, default=int(os.getenv("ANNOTATIONS_PER_IMAGE", "3")))
    return parser.parse_args()


def ensure_dirs(*paths: Path) -> None:
    """필요한 출력 디렉터리를 멱등적으로 생성한다.

    Args:
        *paths (Path): 생성할 디렉터리 경로 목록.
    """
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)


def synthesize_annotation(sample_images: int, sample_categories: int, per_image: int) -> dict[str, Any]:
    """raw annotation이 없을 때 MSCOCO 호환 구조의 sample annotation을 만든다.

    Args:
        sample_images (int): 생성할 image 엔트리 수.
        sample_categories (int): 생성할 category 수.
        per_image (int): image 당 annotation 수.

    Returns:
        dict[str, Any]: images / annotations / categories 키를 가진 MSCOCO-like JSON.
    """
    rng = random.Random(42)
    keywords = ["dog", "cat", "person", "car", "bicycle", "tree", "road", "building"]
    images = [
        {
            "id": image_id,
            "file_name": f"img_{image_id:06d}.jpg",
            "width": 640,
            "height": 480,
        }
        for image_id in range(1, sample_images + 1)
    ]
    categories = [
        {
            "id": category_id,
            "name": keywords[category_id % len(keywords)],
            "supercategory": "object",
        }
        for category_id in range(1, sample_categories + 1)
    ]
    annotations = []
    annotation_id = 1
    for image in images:
        for _ in range(per_image):
            category = rng.choice(categories)
            caption_kw = rng.sample(keywords, k=2)
            annotations.append(
                {
                    "id": annotation_id,
                    "image_id": image["id"],
                    "category_id": category["id"],
                    "caption": f"a {caption_kw[0]} near a {caption_kw[1]}",
                    "bbox": [
                        rng.randint(0, 320),
                        rng.randint(0, 240),
                        rng.randint(32, 320),
                        rng.randint(32, 240),
                    ],
                }
            )
            annotation_id += 1
    return {"images": images, "annotations": annotations, "categories": categories}


def load_or_synthesize_annotation(path: Path, sample_images: int, sample_categories: int, per_image: int) -> tuple[dict[str, Any], bool]:
    """annotation 파일을 읽거나 없으면 sample을 생성한다.

    Args:
        path (Path): MSCOCO 스타일 annotation JSON 경로.
        sample_images (int): 합성 시 image 수.
        sample_categories (int): 합성 시 category 수.
        per_image (int): 합성 시 image 당 annotation 수.

    Returns:
        tuple[dict[str, Any], bool]: annotation payload와 실제 파일에서 읽었는지 여부.
    """
    if path.exists():
        # 작은 metadata read 패턴: JSON 전체를 한 번에 로드 후 인덱싱.
        with path.open("r", encoding="utf-8") as fp:
            return json.load(fp), True
    return synthesize_annotation(sample_images, sample_categories, per_image), False


def tokenize_caption(caption: str) -> list[str]:
    """caption을 소문자 단어 토큰으로 분리한다.

    Args:
        caption (str): annotation caption 텍스트.

    Returns:
        list[str]: 알파벳/숫자 기반 토큰 리스트.
    """
    return [token for token in re.findall(r"[a-zA-Z0-9]+", caption.lower()) if token]


def build_index(annotation: dict[str, Any]) -> dict[str, Any]:
    """image_id / category_id / caption keyword 기반 metadata index를 만든다.

    Args:
        annotation (dict[str, Any]): MSCOCO 호환 annotation payload.

    Returns:
        dict[str, Any]: 다중 키 매핑 index 객체.
    """
    by_image: dict[int, list[int]] = defaultdict(list)
    by_category: dict[int, list[int]] = defaultdict(list)
    keyword_to_annotations: dict[str, list[int]] = defaultdict(list)

    for entry in annotation.get("annotations", []):
        annotation_id = int(entry["id"])
        by_image[int(entry["image_id"])].append(annotation_id)
        by_category[int(entry["category_id"])].append(annotation_id)
        caption = entry.get("caption", "")
        for token in tokenize_caption(caption):
            keyword_to_annotations[token].append(annotation_id)

    category_lookup = {int(c["id"]): c.get("name", str(c["id"])) for c in annotation.get("categories", [])}
    image_lookup = {int(img["id"]): img.get("file_name", "") for img in annotation.get("images", [])}

    return {
        "schema_version": "1",
        "image_lookup": image_lookup,
        "category_lookup": category_lookup,
        "by_image": {str(k): v for k, v in by_image.items()},
        "by_category": {str(k): v for k, v in by_category.items()},
        "by_caption_keyword": {k: v for k, v in keyword_to_annotations.items()},
    }


def main() -> None:
    """annotation을 읽어 metadata index를 만들고 summary를 기록한다."""
    args = parse_args()
    raw_dir = Path(args.raw_dir)
    index_dir = Path(args.index_dir)
    log_dir = Path(args.log_dir)
    ensure_dirs(raw_dir, index_dir, log_dir)

    annotation_path = raw_dir / args.annotation_file
    started = time.perf_counter()
    annotation, loaded_from_disk = load_or_synthesize_annotation(
        annotation_path,
        args.sample_images,
        args.sample_categories,
        args.annotations_per_image,
    )
    if not loaded_from_disk:
        # WHY: dataset-ingest PVC가 비어 있는 경우 sample을 raw_dir에 저장해
        #      large-read → metadata-read 의 두 단계 흐름을 그대로 재현한다.
        annotation_path.write_text(json.dumps(annotation, indent=2, ensure_ascii=False), encoding="utf-8")

    index = build_index(annotation)
    index_path = index_dir / "annotation_index.json"
    index_path.write_text(json.dumps(index, indent=2, ensure_ascii=False), encoding="utf-8")

    summary = {
        "status": "completed",
        "raw_path": str(annotation_path),
        "raw_loaded_from_disk": loaded_from_disk,
        "index_path": str(index_path),
        "images": len(annotation.get("images", [])),
        "categories": len(annotation.get("categories", [])),
        "annotations": len(annotation.get("annotations", [])),
        "keywords_indexed": len(index["by_caption_keyword"]),
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }
    summary_path = log_dir / "annotation_index_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
