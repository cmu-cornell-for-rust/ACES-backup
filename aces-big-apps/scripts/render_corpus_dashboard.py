#!/usr/bin/env python3
"""Render bsan-corpus-dashboard.canvas.tsx from corpus_status_snapshot JSON."""
from __future__ import annotations

import json
import sys
from pathlib import Path

TEMPLATE = r'''import {
  Callout,
  Card,
  CardBody,
  CardHeader,
  Code,
  CollapsibleSection,
  Grid,
  H1,
  H2,
  H3,
  Pill,
  Stack,
  Stat,
  Table,
  Text,
  UsageBar,
} from "cursor/canvas";

const SNAPSHOT = __SNAPSHOT__ as const;

type AppRow = (typeof SNAPSHOT)["apps"][number];

function logStatusTone(status: string | null): "success" | "warning" | "deleted" | "neutral" {
  if (status === "ok") return "success";
  if (status === "test_error") return "warning";
  if (status === "build_error" || status === "fetch_error") return "deleted";
  return "neutral";
}

function slurmTone(state: string | null): "info" | "neutral" | "success" | "warning" | "deleted" {
  if (!state) return "neutral";
  if (state === "RUNNING" || state === "COMPLETING") return "info";
  if (state === "PENDING") return "neutral";
  if (state === "COMPLETED") return "success";
  if (state === "FAILED" || state === "TIMEOUT") return "deleted";
  return "warning";
}

function verdictTone(v: string): "success" | "warning" | "info" | "deleted" | "neutral" {
  if (v === "pass") return "success";
  if (v === "likely_fp") return "info";
  if (v === "investigate" || v === "running") return "warning";
  if (v === "infra" || v === "harness" || v === "harness_cc") return "neutral";
  return "deleted";
}

function rowTone(app: AppRow): "success" | "warning" | "danger" | "info" | undefined {
  if (app.logStatus === "ok") return "success";
  if (app.logStatus === "test_error") return "warning";
  if (app.logStatus === "build_error" || app.logStatus === "fetch_error") return "danger";
  if (app.slurmState === "RUNNING" || app.slurmState === "COMPLETING") return "info";
  return undefined;
}

function fmtStatus(status: string | null): string {
  return status ? status.replace(/_/g, " ") : "—";
}

function verdictLabel(v: string): string {
  const labels = SNAPSHOT.verdictLabels as Record<string, string>;
  return labels[v] ?? v;
}

function interestingApps(): AppRow[] {
  return SNAPSHOT.apps.filter(
    (a) =>
      a.logExcerpt ||
      a.logStatus === "test_error" ||
      a.logStatus === "build_error" ||
      a.slurmState === "RUNNING" ||
      a.slurmState === "COMPLETING",
  );
}

export default function BsanCorpusDashboard() {
  const s = SNAPSHOT.summary;
  const done = s.ok + s.test_error + s.build_error + s.fetch_error + s.other;
  const segments = [
    { id: "ok", value: s.ok, color: "green" as const },
    { id: "test_error", value: s.test_error, color: "orange" as const },
    { id: "build_error", value: s.build_error, color: "pink" as const },
    { id: "in_progress", value: s.in_progress, color: "blue" as const },
    { id: "queued", value: s.queued, color: "gray" as const },
  ].filter((x) => x.value > 0);

  const flagged = interestingApps();

  return (
    <Stack gap={16} style={{ padding: 20, maxWidth: 1100 }}>
      <Stack gap={4}>
        <H1>BSAN Corpus — Live Status</H1>
        <Text tone="secondary" size="small">
          Updated {SNAPSHOT.fetchedAt} UTC · BSAN {SNAPSHOT.bsan.branch} @ {SNAPSHOT.bsan.commit}
          {SNAPSHOT.bsan.subject ? ` — ${SNAPSHOT.bsan.subject}` : ""}
        </Text>
        {SNAPSHOT.submitLog ? (
          <Text tone="tertiary" size="small">Batch: {SNAPSHOT.submitLog}</Text>
        ) : null}
      </Stack>

      <Callout tone="info" title="Main-branch analysis">
        {SNAPSHOT.analysisSummary}
      </Callout>

      <Grid columns={5} gap={10}>
        <Stat label="Queued" value={String(s.queued)} />
        <Stat label="Running" value={String(s.running)} tone="info" />
        <Stat label="Passed" value={String(s.ok)} tone="success" />
        <Stat label="Test errors" value={String(s.test_error)} tone="warning" />
        <Stat label="Build errors" value={String(s.build_error)} tone="danger" />
      </Grid>

      {done > 0 ? (
        <Card>
          <CardHeader trailing={`${done}/${s.total} finished`}>Log outcomes</CardHeader>
          <CardBody>
            <UsageBar
              total={s.total}
              topLeftLabel="Apps with terminal log status"
              topRightLabel={`${done} / ${s.total}`}
              segments={segments}
            />
          </CardBody>
        </Card>
      ) : null}

      <H2>Per-app</H2>
      <Table
        headers={["App", "Verdict", "Slurm", "Log status", "Headline"]}
        rows={SNAPSHOT.apps.map((a) => [
          a.app,
          <Pill tone={verdictTone(a.verdict)} size="sm">{verdictLabel(a.verdict)}</Pill>,
          a.slurmState ? (
            <Pill tone={slurmTone(a.slurmState)} size="sm">{a.slurmState}</Pill>
          ) : (
            "—"
          ),
          a.logStatus ? (
            <Pill tone={logStatusTone(a.logStatus)} size="sm">{fmtStatus(a.logStatus)}</Pill>
          ) : (
            "—"
          ),
          a.headline ?? a.analysis,
        ])}
        rowTone={SNAPSHOT.apps.map((a) => rowTone(a))}
        striped
      />

      <H2>Logs and findings ({flagged.length})</H2>
      <Stack gap={8}>
        {flagged.map((a) => (
          <CollapsibleSection
            key={a.app}
            title={a.app}
            trailing={
              <Pill tone={verdictTone(a.verdict)} size="sm">{verdictLabel(a.verdict)}</Pill>
            }
            defaultOpen={
              a.logStatus === "test_error" ||
              a.logStatus === "build_error" ||
              a.verdict === "likely_fp"
            }
          >
            <Stack gap={6}>
              <Text size="small" tone="secondary">{a.analysis}</Text>
              {a.headline ? (
                <Text size="small" weight="semibold">{a.headline}</Text>
              ) : null}
              {a.logFile ? (
                <Text size="small" tone="tertiary">{a.logFile}</Text>
              ) : null}
              {a.logExcerpt ? (
                <Code style={{ display: "block", whiteSpace: "pre-wrap", fontSize: 11, maxHeight: 280, overflow: "auto" }}>
                  {a.logExcerpt}
                </Code>
              ) : (
                <Text size="small" tone="tertiary">No log excerpt yet.</Text>
              )}
            </Stack>
          </CollapsibleSection>
        ))}
      </Stack>

      {SNAPSHOT.jobs.length > 0 ? (
        <>
          <H3>Slurm queue ({SNAPSHOT.jobs.length})</H3>
          <Table
            headers={["Job ID", "Name", "State", "Elapsed"]}
            rows={SNAPSHOT.jobs.map((j) => [
              j.id,
              j.name,
              <Pill tone={slurmTone(j.state)} size="sm">{j.state}</Pill>,
              j.elapsed || "—",
            ])}
            striped
          />
        </>
      ) : null}

      <Text tone="tertiary" size="small">
        Local poll every 2m via update_corpus_dashboard.sh · read-only SSH to ACES
      </Text>
    </Stack>
  );
}
'''


def main() -> None:
    raw = sys.stdin.read() if len(sys.argv) < 2 else Path(sys.argv[1]).read_text()
    snapshot = json.loads(raw)
    body = json.dumps(snapshot, indent=2)
    out = TEMPLATE.replace("__SNAPSHOT__", body)
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
