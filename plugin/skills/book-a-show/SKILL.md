---
name: book-a-show
description: Book theatre tickets — showtimes, seat availability, and seat selection — using the Showtime MCP App. Use whenever someone asks what is playing, when a show is on, whether seats are left, or wants to pick seats or buy tickets for a performance.
---

# Booking a show

Showtime answers "when is it on and where do we sit" with an interactive view
rather than prose. The user picks the date, the performance, and the exact seats
themselves; you handle everything around that.

## How to use it

Call `book_show_seats` as soon as the request is about performances, seat
availability, or tickets. Pass what the user has already told you so the view
opens pre-filled:

| Argument | Pass it when the user has said… |
| --- | --- |
| `show` | which production ("the lighthouse one", `coriolanus`) |
| `party_size` | how many are going ("me and two friends" → 3) |
| `when` | a specific day, as `YYYY-MM-DD` |

Anything they have not said, leave out — the view has sensible defaults and
picking for them only creates something to undo.

## What not to do

**Do not ask for the date and time in chat first.** That is the one thing the
view is better at than you are: it shows every performance with how full it is,
side by side. Opening it *is* the answer to "what times are available?".

**Do not call `confirm_booking`.** It is the user's click. It exists so the view
can commit the seats they chose; a booking you make on their behalf is one they
did not agree to.

**Do not narrate the seat map.** They can see it.

## After they confirm

The view sends the outcome back into the conversation itself — seats,
performance, total, and a confirmation code — so you will simply receive it.
Acknowledge it briefly and move on to anything that actually follows: adding it
to their calendar, working out when to leave, splitting the cost.

If they change their mind after confirming, call `book_show_seats` again rather
than trying to edit the previous booking; the demo box office has no
cancellation flow.

## When the view cannot render

Hosts that do not support MCP Apps get the tool's text result instead: the show,
the venue, and the next few performances with seats remaining. That is enough to
answer in prose — do that rather than apologising for the missing UI.
