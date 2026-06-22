"""
CloudKitchen Disaster Recovery Agent
=====================================
A LangGraph-based autonomous agent that runs daily via EventBridge.

Graph:  START → observe → reason → [act | skip] → report → END

Nodes
-----
observe  — collect AWS health signals (RDS, ALB, ASG, SQS DLQ)
reason   — LLM (Mistral-7B via HuggingFace) identifies incidents and
           decides recovery actions; falls back to rule-based logic
act      — executes safe automated recovery (scale ASG, send SNS alert)
report   — structured CloudWatch log of every run (healthy or not)
"""

import json
import logging
import os
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from tools import (
    check_alb_targets,
    check_asgs,
    check_dlq,
    check_rds,
    scale_asg,
    send_alert,
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DLQ_ALARM_THRESHOLD = int(os.environ.get("DLQ_ALARM_THRESHOLD", "5"))


# ── Agent State ───────────────────────────────────────────────────────────────

class DRState(TypedDict):
    health: dict          # raw health signals
    incidents: list       # detected incidents [{resource, issue, action, severity}]
    analysis: str         # LLM narrative or rule-based summary
    actions_taken: list   # results of recovery actions
    status: str           # "healthy" | "degraded" — written by report node


# ── Node: observe ─────────────────────────────────────────────────────────────

def observe(state: DRState) -> dict:
    """Collect health signals from all CloudKitchen AWS resources."""
    logger.info("DR Agent — OBSERVE: collecting health signals")
    return {
        "health": {
            "rds":         check_rds(),
            "alb_targets": check_alb_targets(),
            "asgs":        check_asgs(),
            "dlq":         check_dlq(),
        }
    }


# ── Node: reason ──────────────────────────────────────────────────────────────

def reason(state: DRState) -> dict:
    """
    Detect incidents via rule-based checks, then ask the LLM to generate
    a professional incident narrative and prioritised recovery recommendation.
    """
    logger.info("DR Agent — REASON: analysing health signals")
    incidents = _detect_incidents(state["health"])
    analysis  = (
        _llm_analysis(state["health"], incidents)
        if incidents
        else "All CloudKitchen services are healthy. No action required."
    )
    return {"incidents": incidents, "analysis": analysis}


def _detect_incidents(health: dict) -> list:
    """Rule-based incident detection — deterministic and fast."""
    incidents = []

    # RDS
    rds = health.get("rds", {})
    if rds.get("status") not in ("available", "unknown"):
        incidents.append({
            "resource": "RDS/PostgreSQL",
            "issue":    f"DB status is '{rds.get('status')}' (expected 'available')",
            "action":   "alert",
            "severity": "critical",
        })

    # ALB target groups
    for tg_name, tg in health.get("alb_targets", {}).items():
        if isinstance(tg, dict) and tg.get("healthy_count", 1) == 0 and tg.get("total", 0) > 0:
            incidents.append({
                "resource": f"ALB/TargetGroup/{tg_name}",
                "issue":    f"0/{tg.get('total')} targets healthy in {tg_name} ({tg.get('service')} service)",
                "action":   "scale_asg",
                "asg_name": tg.get("asg_name", ""),
                "service":  tg.get("service", "unknown"),
                "severity": "critical",
            })

    # ASGs
    for asg_name, asg in health.get("asgs", {}).items():
        if isinstance(asg, dict) and asg.get("in_service", 1) == 0:
            incidents.append({
                "resource": f"ASG/{asg_name}",
                "issue":    f"0 in-service instances (desired={asg.get('desired')})",
                "action":   "scale_asg",
                "asg_name": asg_name,
                "severity": "critical",
            })

    # SQS DLQ
    dlq = health.get("dlq", {})
    depth = dlq.get("depth", 0)
    if depth > DLQ_ALARM_THRESHOLD:
        incidents.append({
            "resource": "SQS/OrdersDLQ",
            "issue":    f"DLQ has {depth} unprocessed failed messages (threshold={DLQ_ALARM_THRESHOLD})",
            "action":   "alert",
            "severity": "warning",
        })

    return incidents


def _llm_analysis(health: dict, incidents: list) -> str:
    """
    Call Mistral-7B via HuggingFace Inference API using stdlib urllib only.
    No langchain-huggingface / transformers needed — keeps Lambda package small.
    Falls back to rule-based text on any failure.
    """
    import urllib.request

    token = os.environ.get("HUGGINGFACEHUB_API_TOKEN", "").strip()
    if not token:
        logger.warning("HUGGINGFACEHUB_API_TOKEN not set — using rule-based analysis")
        return _rule_based_summary(incidents)

    try:
        model  = os.environ.get("HF_MODEL", "mistralai/Mistral-7B-Instruct-v0.3")
        prompt = (
            "[INST] You are a senior DevOps engineer on-call for CloudKitchen, "
            "a cloud-native food delivery platform on AWS. "
            "Analyse the infrastructure health report below and write a concise "
            "(3-4 sentence) incident summary covering: "
            "(1) what failed, (2) likely root cause, "
            "(3) automated recovery actions taken, (4) estimated time to full recovery. "
            "Be specific and professional.\n\n"
            f"Health Report:\n{json.dumps(health, indent=2, default=str)}\n\n"
            f"Detected Incidents:\n{json.dumps(incidents, indent=2)} [/INST]"
        )

        payload = json.dumps({
            "inputs": prompt,
            "parameters": {
                "max_new_tokens":   220,
                "temperature":      0.2,
                "return_full_text": False,
            },
        }).encode("utf-8")

        req = urllib.request.Request(
            f"https://api-inference.huggingface.co/models/{model}",
            data=payload,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type":  "application/json",
            },
        )

        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())

        if isinstance(result, list) and result:
            text = result[0].get("generated_text", "").strip()
            if text:
                logger.info("LLM analysis complete (%d chars)", len(text))
                return text

        return _rule_based_summary(incidents)

    except Exception as exc:
        logger.warning("LLM call failed (%s) — rule-based fallback", exc)
        return _rule_based_summary(incidents)


def _rule_based_summary(incidents: list) -> str:
    critical = [i for i in incidents if i["severity"] == "critical"]
    warnings = [i for i in incidents if i["severity"] == "warning"]
    parts = []
    if critical:
        parts.append(f"{len(critical)} critical failure(s) on: {', '.join(i['resource'] for i in critical)}")
    if warnings:
        parts.append(f"{len(warnings)} warning(s): {', '.join(i['resource'] for i in warnings)}")
    return (
        f"DR Agent detected {'; '.join(parts)}. "
        "Automated recovery (ASG scale-up + SNS alert) has been triggered. "
        "Manual review recommended within 15 minutes."
    )


# ── Routing ───────────────────────────────────────────────────────────────────

def route(state: DRState) -> str:
    return "act" if state["incidents"] else "report"


# ── Node: act ─────────────────────────────────────────────────────────────────

def act(state: DRState) -> dict:
    """
    Execute safe automated recovery actions.
    Every critical incident triggers an SNS alert.
    Scale-up actions are attempted for ASG-related failures.
    """
    logger.info("DR Agent — ACT: executing %d incident(s)", len(state["incidents"]))
    actions_taken = []
    alerted       = False

    for incident in state["incidents"]:
        # Scale up ASG when target group or ASG itself is degraded
        if incident["action"] == "scale_asg" and incident.get("asg_name"):
            result = scale_asg(incident["asg_name"])
            actions_taken.append(result)
            logger.info("Scale action: %s", result)

        # Send one consolidated SNS alert per run (not one per incident)
        if not alerted and incident["severity"] in ("critical", "warning"):
            subject = f"[CloudKitchen DR] {len(state['incidents'])} incident(s) detected"
            message = (
                f"Automated DR Agent Report\n"
                f"{'=' * 50}\n\n"
                f"Analysis:\n{state['analysis']}\n\n"
                f"Incidents:\n" +
                "\n".join(f"  • [{i['severity'].upper()}] {i['resource']}: {i['issue']}"
                          for i in state["incidents"]) +
                f"\n\nActions taken:\n" +
                ("\n".join(f"  • {a}" for a in actions_taken) or "  • None (alert only)")
            )
            result  = send_alert(subject, message)
            actions_taken.append(result)
            alerted = True

    return {"actions_taken": actions_taken}


# ── Node: report ──────────────────────────────────────────────────────────────

def report(state: DRState) -> dict:
    """Emit a structured CloudWatch log for every run (healthy or not)."""
    run_status = "degraded" if state.get("incidents") else "healthy"
    log_entry = {
        "dr_agent":          "cloudkitchen-dr",
        "incidents_detected": len(state.get("incidents", [])),
        "status":            run_status,
        "analysis":          state.get("analysis", ""),
        "actions_taken":     state.get("actions_taken", []),
        "health_summary": {
            k: ("ok" if not _is_degraded(v) else "degraded")
            for k, v in state.get("health", {}).items()
        },
    }
    logger.info("DR-REPORT: %s", json.dumps(log_entry))
    return {"status": run_status}   # LangGraph 0.2.38+ requires at least one key


def _is_degraded(value) -> bool:
    if isinstance(value, dict):
        if "error" in value:
            return True
        if value.get("status") not in (None, "available", "unknown"):
            return True
        if value.get("healthy_count", 1) == 0 and value.get("total", 0) > 0:
            return True
        if value.get("depth", 0) > DLQ_ALARM_THRESHOLD:
            return True
    return False


# ── Graph ─────────────────────────────────────────────────────────────────────

def build_graph():
    g = StateGraph(DRState)

    g.add_node("observe", observe)
    g.add_node("reason",  reason)
    g.add_node("act",     act)
    g.add_node("report",  report)

    g.add_edge(START,      "observe")
    g.add_edge("observe",  "reason")
    g.add_conditional_edges("reason", route, {"act": "act", "report": "report"})
    g.add_edge("act",      "report")
    g.add_edge("report",   END)

    return g.compile()


# ── Lambda entry point ────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """Triggered by EventBridge daily at 02:00 UTC."""
    logger.info("DR Agent invoked — source: %s", event.get("source", "manual"))

    graph  = build_graph()
    result = graph.invoke({
        "health":        {},
        "incidents":     [],
        "analysis":      "",
        "actions_taken": [],
        "status":        "",
    })

    return {
        "statusCode":        200,
        "incidents_detected": len(result.get("incidents", [])),
        "status":            result.get("status", "healthy"),
        "actions_taken":     result.get("actions_taken", []),
        "analysis":          result.get("analysis", ""),
    }
