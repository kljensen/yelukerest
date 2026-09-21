// The one piece of arithmetic in the page's script: when the next poll
// happens, and when it stops. Run with `bun test authapp/static`.
import { describe, expect, test } from "bun:test";
import { nextPollDelay, POLL_INTERVAL_MS, POLL_LIMIT_MS } from "./repositories.js";

describe("nextPollDelay", () => {
  const now = 1_000_000;
  const deadline = now + POLL_LIMIT_MS;

  test("polls at the interval when the server asked for nothing", () => {
    expect(nextPollDelay(now, deadline, 0)).toBe(POLL_INTERVAL_MS);
    expect(nextPollDelay(now, deadline, undefined)).toBe(POLL_INTERVAL_MS);
    expect(nextPollDelay(now, deadline, -5)).toBe(POLL_INTERVAL_MS);
  });

  test("a Retry-After shorter than the interval does not shorten it", () => {
    expect(nextPollDelay(now, deadline, 1000)).toBe(POLL_INTERVAL_MS);
  });

  test("a longer Retry-After is honoured", () => {
    expect(nextPollDelay(now, deadline, 30_000)).toBe(30_000);
  });

  test("stops at the deadline, inclusive", () => {
    expect(nextPollDelay(deadline - POLL_INTERVAL_MS, deadline, 0)).toBe(POLL_INTERVAL_MS);
    expect(nextPollDelay(deadline - POLL_INTERVAL_MS + 1, deadline, 0)).toBe(-1);
    expect(nextPollDelay(deadline, deadline, 0)).toBe(-1);
  });

  test("a Retry-After that would cross the deadline stops polling", () => {
    expect(nextPollDelay(now, deadline, POLL_LIMIT_MS + 1)).toBe(-1);
    expect(nextPollDelay(deadline - 10_000, deadline, 30_000)).toBe(-1);
  });

  test("the constants are the ones the contract states", () => {
    expect(POLL_INTERVAL_MS).toBe(3000);
    expect(POLL_LIMIT_MS).toBe(120_000);
  });
});
