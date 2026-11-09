# The registry holder's spend cap

The holder runs on a metered cloud host. This page is what crewkit does about its cost, what it
cannot do, and the steps the owner takes. crewkit never runs the owner steps.

## What Fly offers (checked 2026-10-31, against Fly's public docs and forum)

1. **A token that can read an organization's billing or usage but cannot create or change machines:
   not documented.** Fly's token docs describe a read-only organization-scoped token, and its role
   docs give billing access to organization admins only. Neither says a read-only token can read
   billing. crewkit therefore does not read Fly's billing: **the cap is the estimate alone.**
2. **A hard spend limit: not offered.** Fly staff have said a spending cap is not planned. The
   owner can ask Fly billing to configure the organization so it is not charged beyond the credit
   loaded (an owner step, by email); that is a limit at the provider, on top of this one.

If either changes, the estimate stays and a provider figure is added beside it: the higher of the
two decides, and `status` says which one it used.

## The estimate

`CK_HOLDER_MONTHLY_USD` is the machine's price from Fly's pricing page for its size and region,
set by the owner at creation (the holder that reads it is not in this change yet). The estimate is
that price times the fraction of the month the holder has run, counted from its own ticks
(`libexec/ck/spend.sh`). Time without ticks is not counted: a tick adds at most 15 minutes, so a
stopped holder, and a live one that hangs longer than that, add nothing. It is labelled "estimated"
wherever it is shown.

- `registry.spend_cap_usd` (default 5) is the cap; `registry.alert_command` is run once a month at
  80% (the loop runs it at both the alert and the capped level); at 100% the holder stops. Both
  are user-only settings (`docs/settings.md`).
- A machine price over the cap, or of zero, is refused at start (exit 78). **This is the real protection while
  there is no provider figure**: the estimate is at most the monthly price, so with a price under
  the cap it reaches 100% of the cap only if the price equals the cap, in the last moments of the
  month. The 80% alert is likewise reachable only with a price at or above 80% of the cap.
- A cap, a price, a spend or a clock that is not a plain number is refused or read as capped, never
  as zero or as "no cap".
- Every doubt reads as more spend. A state file that is missing, unreadable or malformed counts
  the holder as having run since the first of the month, and so does a first start (a holder
  started late in a month shows that month's estimate from the 1st, which can raise the 80% alert
  early but never stops it early). A well-formed file from an earlier month is a normal rollover:
  the new month starts with its share of the gap since the last tick. A clock that goes
  back adds nothing and never lowers the count or moves the month back; the count starts again only
  when the clock passes the highest month seen (so a clock that jumps ahead into a later month wipes
  the month once), and the new month is charged its share of the gap since the last tick, at most
  15 minutes. A tick that crosses a month boundary from the last tick resets the month's alert, so
  a jumping clock can cause one extra alert and never a hidden one. A clock that jumps ahead and then
  returns carries the rest of the old month into the stored month, so the next real month can start
  with that count (too high, never too low); delete the state file to recover (it is then charged as a
  whole month so far). The state file must live where it
  survives the holder's restarts; a restart that loses it is charged as a whole month so far.

### What the estimate cannot see

- Extra machines: a deploy that leaves an old machine running, or a second holder.
- Anything Fly bills that is not machine time: egress, the root file system, IP addresses.
- Two holders ticking one state file count as one, and their updates can overwrite each other.
- A price the owner sets lower than the machine's real price.

The owner's checks at the provider (the dedicated organization's invoice, the credit limit in step
6 below) are what cover these.

## Owner steps (printed here, never run by crewkit)

1. Create a dedicated Fly organization with its own billing, or a separate account and
   organization. Nothing else of the owner's lives in it.
2. In it, create an app with no public IP and no volume.
3. One machine, at the size and region chosen at creation, auto-stop off, restart policy
   `on-failure`.
4. Set the secrets with `fly secrets` from the owner's password manager, piped, never in argv.
5. Deploy the image (built by `tools/holder-image-build.sh`; `docs/holder.md` arrives with the holder image).
6. Optional: ask Fly billing to stop charging beyond the credit loaded.
7. When the holder has stopped at the cap, it stays stopped until the owner raises the cap or a new
   month starts.

## Not yet wired

This change is the library and its settings. The holder loop's check (writing `holder-capped` to the
registry and stopping), the `status` spend line and the `doctor` check are added once the holder
(`libexec/crewkit-holder-run`), `status` and `doctor` branches land.
