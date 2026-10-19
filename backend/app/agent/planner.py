"""Goal decomposition.

Splits a natural-language goal into ordered, capability-tagged steps and ranks
the catalog against each step. Deterministic and dependency-free so it runs
identically in tests, offline and in CI; an LLM planner can be dropped in behind
``decompose`` without touching the graph.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..algorand import asset_id as mandated_asset_id
from ..models import Provider, Service

SPLIT_PATTERN = re.compile(
    r"\s*(?:,\s*then\s+|\s+then\s+|;\s*|\.\s+|\s+and then\s+|\s+after that\s+|->|→)\s*",
    re.IGNORECASE,
)
STOPWORDS = {
    "the", "a", "an", "of", "for", "to", "and", "with", "in", "on", "my", "me",
    "please", "it", "this", "that", "then", "from", "into", "using", "use", "run",
    "get", "make", "do", "give", "some", "all", "by", "as", "is", "are", "be",
}

CAPABILITY_HINTS = {
    "hash": ["hash", "sha", "checksum", "digest", "integrity"],
    "transform": ["transform", "convert", "format", "parse", "clean", "normalize", "reshape"],
    "analyze": ["analyze", "analyse", "statistics", "stats", "summarize", "summary", "report",
                "aggregate", "mean", "median", "insight"],
    "compute": ["compute", "calculate", "sum", "math", "matrix", "simulate", "solve", "prime",
                "fibonacci", "number"],
    "text": ["text", "word", "sentence", "token", "sentiment", "language", "string"],
    "image": ["image", "thumbnail", "resize", "picture", "png", "jpeg"],
    "fetch": ["fetch", "download", "scrape", "http", "api", "url", "crawl"],
    "validate": ["validate", "verify", "check", "lint", "schema"],
}


@dataclass
class PlanStep:
    index: int
    goal: str
    capability: str
    keywords: list[str] = field(default_factory=list)
    service_id: str | None = None
    service_slug: str = ""
    provider_slug: str = ""
    estimated_micros: int = 0
    # Estimates are micro-units of this ASA, never a bare number.
    asset_id: int = field(default_factory=mandated_asset_id)
    status: str = "pending"
    job_id: str | None = None
    output: dict | None = None
    error: str = ""

    def as_dict(self) -> dict:
        return {
            "index": self.index,
            "goal": self.goal,
            "capability": self.capability,
            "keywords": self.keywords,
            "service_id": self.service_id,
            "service_slug": self.service_slug,
            "provider_slug": self.provider_slug,
            "estimated_micros": self.estimated_micros,
            "asset_id": self.asset_id,
            "status": self.status,
            "job_id": self.job_id,
            "output": self.output,
            "error": self.error,
        }


def tokenize(text: str) -> list[str]:
    return [t for t in re.findall(r"[a-z0-9]+", text.lower()) if t not in STOPWORDS and len(t) > 2]


def infer_capability(text: str) -> str:
    tokens = set(tokenize(text))
    best, best_score = "compute", 0
    for capability, hints in CAPABILITY_HINTS.items():
        score = sum(1 for h in hints if h in tokens or any(h in t for t in tokens))
        if score > best_score:
            best, best_score = capability, score
    return best


def decompose(goal: str, max_steps: int = 12) -> list[PlanStep]:
    parts = [p.strip(" .") for p in SPLIT_PATTERN.split(goal or "") if p.strip(" .")]
    if not parts:
        parts = [goal.strip() or "run a compute task"]
    steps: list[PlanStep] = []
    for i, part in enumerate(parts[:max_steps]):
        steps.append(
            PlanStep(index=i, goal=part, capability=infer_capability(part), keywords=tokenize(part))
        )
    return steps


def rank_services(db: Session, step: PlanStep, *, budget_micros: int,
                  min_reputation: float = 0.0) -> list[dict]:
    """Score catalog services against a step: relevance x reputation / price."""
    services = db.scalars(select(Service).where(Service.is_active.is_(True))).all()
    scored: list[dict] = []
    step_tokens = set(step.keywords) | {step.capability}

    for service in services:
        provider = db.get(Provider, service.provider_id)
        if provider is None or not provider.is_active:
            continue
        # Budget is denominated in the mandated asset, so a provider that does
        # not take it is not comparable on price at all.
        if (provider.payment_asset_id or mandated_asset_id()) != mandated_asset_id():
            continue
        if service.max_price_micros > budget_micros:
            continue
        if provider.reputation_score < min_reputation:
            continue

        hay = set(tokenize(" ".join([service.name, service.description, service.category,
                                     service.slug, " ".join(service.tags or [])])))
        overlap = len(step_tokens & hay)
        category_bonus = 3 if service.category == step.capability else 0
        tag_bonus = 2 if step.capability in {t.lower() for t in (service.tags or [])} else 0
        relevance = overlap + category_bonus + tag_bonus
        if relevance == 0:
            continue
        price = max(service.max_price_micros, 1)
        score = relevance * (provider.reputation_score + 10) / (price ** 0.3)
        scored.append(
            {
                "service_id": service.id,
                "slug": service.slug,
                "name": service.name,
                "provider_id": provider.id,
                "provider_slug": provider.slug,
                "reputation": provider.reputation_score,
                "price_micros": service.max_price_micros,
                "asset_id": provider.payment_asset_id or mandated_asset_id(),
                "relevance": relevance,
                "score": round(score, 4),
            }
        )
    return sorted(scored, key=lambda c: c["score"], reverse=True)
