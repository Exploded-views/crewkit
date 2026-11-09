#!/usr/bin/env python3
"""herdr_shape.py FIXTURE: check each JSON line on stdin against the parts of herdr's API schema
in FIXTURE (tests/fixtures/herdr/agent-schema.json, copied from `herdr api schema --json`).

A line is a success response (agent_info, agent_prompted or agent_list), an error response, or a
status --json / session list --json document (no id/result wrapper).
Prints one line per problem and exits 1 if there are any; exit 0 when every line fits.
Used by tests/herdr-stub.bats, so the stub herdr can't drift from real herdr's shape again.
"""
import json
import sys

TYPES = {"string": str, "integer": int, "boolean": bool, "object": dict, "array": list, "null": type(None)}


def fits(value, kinds, schema):
    for kind in kinds:
        if kind == "$ref:AgentStatus":
            if value in schema["AgentStatus"]:
                return True
        elif kind.startswith("$ref:"):
            if isinstance(value, dict):
                return True
        elif kind == "integer":
            if isinstance(value, int) and not isinstance(value, bool):
                return True
        elif isinstance(value, TYPES[kind]):
            return True
    return False


def agent_problems(agent, schema, where):
    info = schema["AgentInfo"]
    if not isinstance(agent, dict):
        return [f"{where}: not an object"]
    out = [f"{where}: missing required {k}" for k in info["required"] if k not in agent]
    for k, v in agent.items():
        if k not in info["properties"]:
            out.append(f"{where}: {k} is not in herdr's AgentInfo")
        elif not fits(v, info["properties"][k], schema):
            out.append(f"{where}: {k}={v!r} is not {info['properties'][k]}")
    return out


def doc_problems(obj, spec, where):
    if not isinstance(obj, dict):
        return [f"{where}: not an object"]
    out = [f"{where}: missing {k}" for k in spec if k not in obj]
    for k, v in obj.items():
        if k not in spec:
            out.append(f"{where}: {k} is not a field herdr has here")
        elif not fits(v, spec[k], {}):
            out.append(f"{where}: {k}={v!r} is not {spec[k]}")
    return out


def document_problems(doc, schema):
    """status --json and session list --json: documents with no id/result wrapper."""
    docs = schema["documents"]
    if "sessions" in doc:
        if not isinstance(doc["sessions"], list):
            return ["sessions is not an array"]
        out = []
        for i, s in enumerate(doc["sessions"]):
            out += doc_problems(s, docs["session_list"]["item"], f"sessions[{i}]")
        return out + [f"extra top-level {k}" for k in doc if k != "sessions"]
    spec = docs["status"]
    out = [f"missing {k}" for k in spec["required"] if k not in doc]
    for part in spec["required"]:
        if part in doc:
            out += doc_problems(doc[part], spec[part], part)
    return out + [f"extra top-level {k}" for k in doc if k not in spec["required"]]


def problems(doc, schema):
    if "sessions" in doc or "client" in doc:
        return document_problems(doc, schema)
    if "error" in doc:
        out = [f"error response: missing {k}" for k in schema["error_response"]["required"] if k not in doc]
        body = doc.get("error")
        if not isinstance(body, dict):
            return out + ["error response: error is not an object"]
        return out + [f"error response: missing error.{k}" for k in schema["error_response"]["error_required"]
                      if not isinstance(body.get(k), str)]
    out = [f"missing {k}" for k in schema["success_response"]["required"] if k not in doc]
    result = doc.get("result")
    if not isinstance(result, dict):
        return out + ["result is not an object"]
    variant = next((r for r in schema["results"] if r["type"] == result.get("type")), None)
    if variant is None:
        return out + [f"result type {result.get('type')!r} is not one the stub may answer with"]
    out += [f"{variant['type']}: missing {k}" for k in variant["required"] if k not in result]
    if variant["agent"]:
        out += agent_problems(result.get("agent"), schema, variant["type"] + ".agent")
    if variant["agents"]:
        agents = result.get("agents")
        if not isinstance(agents, list):
            out.append(f"{variant['type']}.agents is not an array")
        else:
            for i, a in enumerate(agents):
                out += agent_problems(a, schema, f"{variant['type']}.agents[{i}]")
    return out


def main():
    schema = json.load(open(sys.argv[1], encoding="utf-8"))
    bad = 0
    for n, line in enumerate(sys.stdin, 1):
        if not line.strip():
            continue
        try:
            doc = json.loads(line)
        except ValueError:
            print(f"line {n}: not JSON")
            bad += 1
            continue
        for p in problems(doc, schema):
            print(f"line {n}: {p}")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
