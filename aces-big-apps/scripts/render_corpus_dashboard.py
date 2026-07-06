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
      a.isRerun ||
      a.logExcerpt ||
      a.logStatus === "test_error" ||
      a.logStatus === "build_error" ||
      a.slurmState === "RUNNING" ||
      a.slurmState === "COMPLETING",
  );
}

export default function BsanCorpusDashboard() {
  const s = SNAPSHOT.summary;
  const rb = SNAPSHOT.rerunBatch;
  const done = s.ok + s.test_error + s.build_error + s.fetch_error + s.other;
  const segments = [
    { id: "ok", value: s.ok, color: "green" as const },
    { id: "test_error", value: s.test_error, color: "orange" as const },
    { id: "build_error", value: s.build_error, color: "pink" as const },
    { id: "in_progress", value: s.in_progress, color: "blue" as const },
    { id: "queued", value: s.queued, color: "gray" as const },
  ].filter((x) => x.value > 0);

  const flagged = interestingApps();
  const rerunLive = Boolean(rb?.active);

  return (
    <Stack gap={16} style={{ padding: 20, maxWidth: 1100 }}>
      <Stack gap={4}>
        <H1>BSAN Corpus — Live Status</H1>
        <Text tone="secondary" size="small">
          Updated {SNAPSHOT.fetchedAt} UTC
          {SNAPSHOT.pollInterval ? ` · polling every ${SNAPSHOT.pollInterval}` : ""}
          {" · BSAN "}{SNAPSHOT.bsan.branch} @ {SNAPSHOT.bsan.commit}
          {SNAPSHOT.bsan.subject ? ` — ${SNAPSHOT.bsan.subject}` : ""}
        </Text>
        {SNAPSHOT.submitLog ? (
          <Text tone="tertiary" size="small">Latest submit: {SNAPSHOT.submitLog}</Text>
        ) : null}
      </Stack>

      {rerunLive ? (
        <Callout tone="warning" title={`Rerun batch ${rb.stamp ?? "active"}`}>
          <Stack gap={8}>
            <Text size="small">
              Live tracking {rb.apps?.length ?? 0} app(s): {rb.apps?.join(", ") ?? "—"}
            </Text>
            <Table
              headers={["App", "Job", "Slurm", "Log", "Latest"]}
              rows={(rb.rows ?? []).map((r) => [
                r.app,
                r.jobId ?? "—",
                <Pill tone={slurmTone(r.state === "—" ? null : r.state)} size="sm">
                  {r.state ?? "—"}
                </Pill>,
                r.logStatus ? (
                  <Pill tone={logStatusTone(r.logStatus)} size="sm">{fmtStatus(r.logStatus)}</Pill>
                ) : (
                  <Pill tone="info" size="sm">live</Pill>
                ),
                r.headline ?? "—",
              ])}
              striped
            />
          </Stack>
        </Callout>
      ) : null}

      <Callout tone="info" title="Summary">
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
          a.isRerun ? `${a.app} ↻` : a.app,
          <Pill tone={verdictTone(a.verdict)} size="sm">{verdictLabel(a.verdict)}</Pill>,
          a.slurmState ? (
            <Pill tone={slurmTone(a.slurmState)} size="sm">
              {a.slurmState}{a.slurmElapsed ? ` ${a.slurmElapsed}` : ""}
            </Pill>
          ) : (
            "—"
          ),
          a.logStatus ? (
            <Pill tone={logStatusTone(a.logStatus)} size="sm">{fmtStatus(a.logStatus)}</Pill>
          ) : a.slurmState === "RUNNING" || a.slurmState === "COMPLETING" ? (
            <Pill tone="info" size="sm">live</Pill>
          ) : (
            "—"
          ),
          a.headline ?? a.analysis,
        ])}
        rowTone={SNAPSHOT.apps.map((a) => rowTone(a))}
        striped
      />

      {SNAPSHOT.servoFonts ? (
        <>
          <H2>Servo-fonts (jemalloc track)</H2>
          <Card>
            <CardBody>
              <Stack gap={6}>
                <Text size="small">
                  Job {SNAPSHOT.servoFonts.jobId ?? "—"}
                  {SNAPSHOT.servoFonts.state ? (
                    <> · <Pill tone={slurmTone(SNAPSHOT.servoFonts.state)} size="sm">{SNAPSHOT.servoFonts.state}</Pill></>
                  ) : null}
                  {SNAPSHOT.servoFonts.elapsed ? ` · ${SNAPSHOT.servoFonts.elapsed}` : ""}
                </Text>
                {SNAPSHOT.servoFonts.headline ? (
                  <Text size="small" weight="semibold">{SNAPSHOT.servoFonts.headline}</Text>
                ) : null}
                {SNAPSHOT.servoFonts.logExcerpt ? (
                  <Code style={{ display: "block", whiteSpace: "pre-wrap", fontSize: 11, maxHeight: 200, overflow: "auto" }}>
                    {SNAPSHOT.servoFonts.logExcerpt}
                  </Code>
                ) : null}
              </Stack>
            </CardBody>
          </Card>
        </>
      ) : null}

      {SNAPSHOT.infraJobs && SNAPSHOT.infraJobs.length > 0 ? (
        <>
          <H2>Infra / setup jobs</H2>
          <Table
            headers={["Job ID", "Name", "State", "Elapsed", "Tail"]}
            rows={SNAPSHOT.infraJobs.map((j) => [
              j.id,
              j.name,
              <Pill tone={slurmTone(j.state)} size="sm">{j.state}</Pill>,
              j.elapsed || "—",
              j.logExcerpt ? j.logExcerpt.split("\n").slice(-1)[0]?.slice(0, 80) ?? "—" : "—",
            ])}
            striped
          />
        </>
      ) : null}

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
              a.isRerun ||
              a.logStatus === "test_error" ||
              a.logStatus === "build_error" ||
              a.verdict === "likely_fp" ||
              a.slurmState === "RUNNING" ||
              a.slurmState === "COMPLETING"
            }
          >
            <Stack gap={6}>
              <Text size="small" tone="secondary">{a.analysis}</Text>
              {a.isRerun ? (
                <Pill tone="info" size="sm">rerun batch</Pill>
              ) : null}
              {a.headline ? (
                <Text size="small" weight="semibold">{a.headline}</Text>
              ) : null}
              {a.logFile ? (
                <Text size="small" tone="tertiary">
                  {a.logSource === "sbatch" ? "sbatch log" : "corpus log"}: {a.logFile}
                  {a.slurmId ? ` (job ${a.slurmId})` : ""}
                </Text>
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
        Local poll via update_corpus_dashboard.sh --loop {SNAPSHOT.pollInterval ?? "30s"} · read-only SSH to ACES
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
