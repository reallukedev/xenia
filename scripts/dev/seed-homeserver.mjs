#!/usr/bin/env node
// Fills the local test homeserver (http://localhost:8008) with accounts, rooms and messages, so
// every screen has realistic data. Safe to run again: existing accounts sign in, and rooms are
// only created when their alias doesn't exist yet.
//
//   node scripts/dev/seed-homeserver.mjs
// Test accounts (local server only). Sign in to the app as @luke:localhost.
export const HOMESERVER = process.env.XENIA_HOMESERVER ?? 'http://localhost:8008';
export const PASSWORD = 'relay-dev-password';

const PEOPLE = {
  luke: 'Luke',
  maya: 'Maya Okafor',
  sam: 'Sam Reyes',
  priya: 'Priya Natarajan',
  jordan: 'Jordan Blake',
  alex: 'Alex Chen',
  // A deliberately long name, for truncation in lists and headers.
  christopher: 'Christopher Montgomery-Wellington III',
};

async function api(token, method, path, body) {
  const res = await fetch(`${HOMESERVER}/_matrix/client/v3${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`${method} ${path}: ${res.status} ${json.errcode ?? ''} ${json.error ?? ''}`);
    err.errcode = json.errcode;
    throw err;
  }
  return json;
}

async function account(username) {
  try {
    const r = await api(null, 'POST', '/register', {
      username,
      password: PASSWORD,
      auth: { type: 'm.login.dummy' },
      initial_device_display_name: 'Seed script',
    });
    return { userId: r.user_id, token: r.access_token };
  } catch (e) {
    if (e.errcode !== 'M_USER_IN_USE') throw e;
    const r = await api(null, 'POST', '/login', {
      type: 'm.login.password',
      identifier: { type: 'm.id.user', user: username },
      password: PASSWORD,
      initial_device_display_name: 'Seed script',
    });
    return { userId: r.user_id, token: r.access_token };
  }
}

/**
 * Lists a room in the public room directory. Safe to repeat. Synapse refuses when the server's
 * room_list_publication_rules don't allow it (the default since 1.126 allows nobody), so that
 * only warns: the room is still public to join, it just won't show up when browsing.
 */
async function listPublicly(user, roomId, alias) {
  try {
    await api(user.token, 'PUT', `/directory/list/room/${encodeURIComponent(roomId)}`, { visibility: 'public' });
  } catch (e) {
    if (e.errcode !== 'M_UNKNOWN' && e.errcode !== 'M_FORBIDDEN') throw e;
    console.warn(
      `#${alias}:localhost isn't in the room directory: the server doesn't allow publishing. ` +
        'Add "room_list_publication_rules: [{ action: allow }]" to homeserver.yaml, restart it, and run this again.',
    );
  }
}

async function roomByAlias(token, localpart) {
  try {
    const r = await api(token, 'GET', `/directory/room/${encodeURIComponent(`#${localpart}:localhost`)}`);
    return r.room_id;
  } catch {
    return null;
  }
}

let txn = Date.now();
/** Sends a message and returns its event id. Takes plain text, or a full content object. */
async function say(user, roomId, message) {
  const content = typeof message === 'string' ? { msgtype: 'm.text', body: message } : { msgtype: 'm.text', ...message };
  const r = await api(user.token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${txn++}`, content);
  return r.event_id;
}

/** A message that mentions Luke as clients send it: "{luke}" becomes his name, and a pill. */
function mentioningLuke(text) {
  return {
    body: text.replace('{luke}', 'Luke'),
    format: 'org.matrix.custom.html',
    formatted_body: text.replace('{luke}', '<a href="https://matrix.to/#/@luke:localhost">Luke</a>'),
    'm.mentions': { user_ids: ['@luke:localhost'] },
  };
}

// The newest event in each thread, so every reply quotes the one before it, as clients do.
const threadTips = new Map();

/** Posts a thread reply (MSC3440) under rootId and returns its event id. */
async function reply(user, roomId, rootId, text) {
  const eventId = await say(user, roomId, {
    body: text,
    'm.relates_to': {
      rel_type: 'm.thread',
      event_id: rootId,
      is_falling_back: true,
      'm.in_reply_to': { event_id: threadTips.get(rootId) ?? rootId },
    },
  });
  threadTips.set(rootId, eventId);
  return eventId;
}

async function setState(user, roomId, type, content, stateKey = '') {
  await api(user.token, 'PUT', `/rooms/${encodeURIComponent(roomId)}/state/${type}/${encodeURIComponent(stateKey)}`, content);
}

async function join(user, roomId) {
  await api(user.token, 'POST', `/join/${encodeURIComponent(roomId)}`, {});
}

async function directRooms(user) {
  try {
    return await api(user.token, 'GET', `/user/${encodeURIComponent(user.userId)}/account_data/m.direct`);
  } catch {
    return {};
  }
}

/** Adds a DM to a user's m.direct map, keeping the ones already there. */
async function markDirect(user, otherId, roomId) {
  const map = await directRooms(user);
  map[otherId] = [...new Set([...(map[otherId] ?? []), roomId])];
  await api(user.token, 'PUT', `/user/${encodeURIComponent(user.userId)}/account_data/m.direct`, map);
}

/**
 * Creates a room once and plays its script. Group rooms are found again by alias; DMs have no
 * alias (real ones don't), so they're found through the creator's m.direct map.
 *
 * A script is a list of [person, message] pairs, or an async function (roomId) => {} for rooms
 * that need threads, pins or other extras. Public rooms pass isPublic to use the public_chat
 * preset and appear in the room directory.
 */
async function room(u, { alias, creator, name, topic, members, isDirect, isPublic, invitesOnly = [], script }) {
  if (isDirect) {
    const existing = (await directRooms(u[creator]))[u[members[0]].userId]?.[0];
    if (existing) return existing;
  } else {
    const existing = await roomByAlias(u[creator].token, alias);
    if (existing) return existing;
  }
  const { room_id: roomId } = await api(u[creator].token, 'POST', '/createRoom', {
    ...(isDirect ? {} : { room_alias_name: alias }),
    preset: isDirect ? 'trusted_private_chat' : isPublic ? 'public_chat' : 'private_chat',
    ...(isPublic ? { visibility: 'public' } : {}),
    ...(name ? { name } : {}),
    ...(topic ? { topic } : {}),
    is_direct: Boolean(isDirect),
    invite: [...members, ...invitesOnly].map((m) => u[m].userId),
  });
  for (const m of members) await join(u[m], roomId);
  if (isDirect) {
    // Mark the DM in both people's account data, as clients do.
    await markDirect(u[creator], u[members[0]].userId, roomId);
    await markDirect(u[members[0]], u[creator].userId, roomId);
  }
  if (typeof script === 'function') await script(roomId);
  else for (const [who, text] of script) await say(u[who], roomId, text);
  return roomId;
}

/** 400 messages cycling through a few people and lines, numbered so any spot can be found. */
function coffeeChat() {
  const people = ['maya', 'sam', 'jordan', 'luke'];
  const lines = [
    'Tried the new Ethiopian roast this morning, very bright',
    'Pour over or AeroPress today?',
    'The grinder at work is finally fixed',
    'Oat milk ran out again',
    'Anyone want to split a bag of the Colombian beans?',
    'Cold brew season is officially over',
    'That café on 5th does a great cortado',
    'I switched to a finer grind and it made a huge difference',
  ];
  const script = [];
  for (let i = 0; i < 400; i++) {
    const who = people[i % people.length];
    // The oldest stretch talks about bread, so a search for it has to reach far back.
    const line = i < 20 ? `Day ${i + 1} of the sourdough starter: it smells like apples` : lines[i % lines.length];
    script.push([who, `${line} (#${i + 1})`]);
  }
  return script;
}

// About 120 messages spanning a week of planning, the walk itself and the day after. The server
// stamps them all with the time they're sent, so the days here live in the words only.
const PHOTO_WALKS = [
  // Tuesday
  ['jordan', 'Photo walk this Saturday? The forecast says clear skies until noon.'],
  ['priya', "I'm in!"],
  ['alex', 'In. Where are we thinking?'],
  ['jordan', 'The old rail yard by the river. The light through the water tower is unreal at 8am.'],
  ['luke', '8am on a Saturday is a big ask, Jordan'],
  ['jordan', 'The golden hour waits for no one'],
  ['priya', 'I will bring coffee if that helps'],
  ['luke', "It helps a lot. Okay, I'm in."],
  ['alex', 'Should we bring tripods or travel light?'],
  ['jordan', 'Travel light. Maybe a small one if you want to try long exposures on the river.'],
  ['priya', 'I just got a 35mm prime and I am desperate to use it'],
  ['alex', 'Ooh which one?'],
  ['priya', "The Sigma f/1.4. Secondhand, but it's basically mint."],
  ['luke', "Great lens. You'll never take it off."],
  ['alex', "I'm going to be the one person shooting on my phone again"],
  ['jordan', 'Phones are cameras! Some of my favorite shots from last month were yours.'],
  ['alex', "That's kind. The pigeon one?"],
  ['jordan', 'The pigeon one. Iconic.'],
  ['priya', 'That pigeon deserves an agent'],
  ['luke', 'Printing it for my fridge honestly'],
  // Wednesday
  ['priya', 'Does anyone know if the rail yard has parking?'],
  ['jordan', 'There is a small lot on Mercer Street. It fills up with the farmers market crowd around 9.'],
  ['alex', "I can bike over, it's only 15 minutes from me"],
  ['luke', "I'll drive. Priya, want a lift?"],
  ['priya', "Yes please! I'll be the one outside with two coffees."],
  ['jordan', 'Quick poll: after the walk, brunch or the flea market?'],
  ['alex', 'Why not both'],
  ['luke', 'Both. Obviously both.'],
  ['priya', 'Flea market first, the good film cameras go early'],
  ['jordan', 'Priya is not messing around'],
  ['priya', 'Last time someone got a Pentax K1000 for twenty dollars. I think about it daily.'],
  ['alex', 'Okay now I want a film camera'],
  ['luke', "That's how it starts. Next thing you know your fridge is full of Portra."],
  ['alex', 'Is that bad?'],
  ['luke', "It's wonderful and very expensive"],
  ['jordan', 'Sharing a few favorites from last month so we can pick up where we left off.'],
  ['jordan', "Last month's favorites:\n1. The water tower at sunrise\n2. Alex's pigeon (obviously)\n3. Priya's reflection shot in the puddle by the bridge\n4. Luke's long exposure of the freight train"],
  ['priya', 'The puddle one still makes me happy'],
  ['alex', 'The freight train shot looks like a painting'],
  ['luke', 'That was pure luck, I was mostly trying to keep my hands warm'],
  // Thursday
  ['alex', 'Question for the group: how do you all deal with harsh midday light?'],
  ['jordan', 'Honestly I mostly stop shooting landscapes and go looking for shade and small details'],
  ['priya', 'Hard shadows can be great for black and white. Lean into the contrast.'],
  ['luke', 'A polarizer helps a lot with reflections and the sky. I can lend you mine on Saturday.'],
  ['alex', 'Would love that, thank you'],
  ['jordan', 'Also, shoot the people! Midday is great for candid street stuff.'],
  ['alex', 'I always feel awkward pointing a camera at strangers'],
  ['priya', 'Same. I usually ask first, and most people are lovely about it.'],
  ['luke', 'The woman at the flower stall let me photograph her for almost an hour last spring. She showed me pictures of her grandkids the whole time and sent me home with a bunch of tulips. Still one of my favorite mornings.'],
  ['jordan', "That's the best part of these walks, the people you meet"],
  ['alex', "Okay, I'll be brave this time"],
  ['priya', 'We believe in you'],
  ['jordan', 'Weather update: still clear on Saturday, a little wind in the afternoon'],
  ['luke', 'Good day for clouds after lunch then'],
  ['alex', "What's the plan if it rains?"],
  ['jordan', 'The covered market has amazing light through the glass roof. Rain plan sorted.'],
  ['priya', 'I kind of hope it rains now'],
  ['luke', "Don't jinx it"],
  ['priya', '🤞'],
  ['alex', 'Should I bring anything?'],
  // Friday
  ['jordan', "Alex, just yourself and comfy shoes. We'll probably walk about five miles."],
  ['alex', 'Five miles!'],
  ['luke', "It goes by fast, there's so much to stop and look at"],
  ['priya', 'And the coffee helps'],
  ['jordan', 'Meeting spot: the east gate of the rail yard, by the red signal box. 7:45.'],
  ['luke', '7:45?? You said 8'],
  ['jordan', "7:45 so we're shooting by 8 😇"],
  ['luke', 'Betrayal'],
  ['priya', "I'll make your coffee extra strong"],
  ['alex', 'Charging batteries now. Well, battery. Phone.'],
  ['luke', 'Bring a power bank, your phone will be dead by 10 if you shoot RAW'],
  ['alex', 'Good call'],
  ['priya', 'Formatting my cards. It feels like the night before a school trip.'],
  ['jordan', "It really does. I'm packing snacks too."],
  ['luke', 'What kind of snacks'],
  ['jordan', 'The good granola bars and a bag of clementines'],
  ['alex', 'Jordan is the parent of this group'],
  ['jordan', 'Someone has to be'],
  ['priya', 'Goodnight all, see you bright and early'],
  ['luke', 'Early, anyway'],
  // Saturday
  ['jordan', "I'm here! The light is already doing the thing."],
  ['priya', 'Two minutes away, coffee in hand'],
  ['luke', 'Parking now. One spot left, we got lucky.'],
  ['alex', "I'm by the signal box. Is that a heron on the roof??"],
  ['jordan', 'It is! Get the shot!'],
  ['alex', 'Got it. I think. My hands were shaking.'],
  ['priya', "That's the pigeon's successor right there"],
  ['luke', 'The mist coming off the river is incredible right now'],
  ['jordan', 'Everyone look west in about five minutes, the sun is about to hit the water tower'],
  ['priya', 'Oh wow'],
  ['alex', 'I took about 40 photos of the same thing'],
  ['luke', "That's the correct number"],
  ['jordan', 'Heading toward the bridge. Catch up when you can.'],
  ['priya', 'Stopped at the flower stall and she remembered Luke!'],
  ['luke', "She did?? That's made my week"],
  ['alex', 'I asked a man with a magnificent mustache if I could photograph him. He said yes and then gave me a pear.'],
  ['jordan', 'This is the content we come for'],
  ['priya', 'Flea market update: no K1000 today, but I found a Canon AE-1 for thirty five dollars'],
  ['alex', 'Priya!!'],
  ['luke', "That's a great deal. Does the light meter work?"],
  ['priya', 'The needle moves! The seller threw in a roll of Ektar too.'],
  ['jordan', 'Brunch at Juniper? They have a table for four in 15 minutes.'],
  ['alex', 'On my way, I smell pancakes from here'],
  // Sunday
  ['jordan', "Thank you all for yesterday. That was one of the best walks we've done."],
  ['priya', 'Agreed. My legs are sore in the best way.'],
  ['alex', 'I checked my step count: 14,302'],
  ['luke', 'Uploading my favorites to the shared album tonight'],
  ['alex', "Be honest: is the heron shot too soft? I can't tell on my phone screen."],
  ['jordan', "It's a little soft, but the composition is perfect. Soft is fine. It feels like a memory."],
  ['priya', "That's a beautiful way to put it"],
  ['luke', "Agree with Jordan. Crop it a little tighter and it's a print."],
  ['alex', "Okay I'm printing it. Pigeon and heron, side by side."],
  ['priya', 'The bird series begins'],
  ['jordan', "A few notes for next time, while they're fresh:\n\n- 7:45 was the right call (sorry Luke)\n- Bring a lens cloth, the mist was brutal\n- The bridge is best before 9, after that the joggers arrive\n- Flea market first, brunch second, as Priya decreed"],
  ['luke', 'Apology accepted. Mostly.'],
  ['priya', 'Adding "as Priya decreed" to my email signature'],
  ['alex', "When's the next one?"],
  ['jordan', 'Two weeks? The leaves in the park should be turning by then.'],
  ['priya', "Yes! Autumn colors with the new lens, I can't wait"],
  ['luke', "Count me in. I'll even show up at 7:45."],
  ['alex', "Can I bring my sister? She just got her first camera and she's very excited."],
  ['jordan', 'Of course! The more the merrier.'],
];

async function main() {
  const u = {};
  for (const [name, displayName] of Object.entries(PEOPLE)) {
    u[name] = await account(name);
    await api(u[name].token, 'PUT', `/profile/${encodeURIComponent(u[name].userId)}/displayname`, { displayname: displayName });
  }

  await room(u, {
    alias: 'dm-luke-maya',
    creator: 'maya',
    members: ['luke'],
    isDirect: true,
    script: [
      ['maya', 'Are you still up for climbing on Thursday?'],
      ['luke', 'Yes! 6:30 at the usual gym?'],
      ['maya', 'Perfect. I finally sent that green V4 on the overhang btw'],
      ['luke', 'No way, the one with the awful crimp at the top?'],
      ['maya', 'That one. Took me eleven tries. My fingers are still angry about it.'],
      ['maya', 'Bring chalk, I keep forgetting mine'],
    ],
  });

  await room(u, {
    alias: 'dm-luke-sam',
    creator: 'luke',
    members: ['sam'],
    isDirect: true,
    script: [
      ['luke', 'Did the invoice for the Henderson project go out?'],
      ['sam', 'Sent it this morning. They said payment should land by the 15th.'],
      ['luke', 'Great, thank you'],
      ['sam', 'Also, the client asked if we can move the review to next Tuesday. Does that work for you?'],
    ],
  });

  await room(u, {
    alias: 'weekend-trip',
    creator: 'priya',
    name: 'Weekend Trip',
    topic: 'Big Sur, October 17 to 19',
    members: ['luke', 'maya', 'jordan'],
    script: [
      ['priya', 'Okay, the cabin is booked! Friday to Sunday.'],
      ['jordan', 'Amazing. Who is driving?'],
      ['maya', 'I can take four people, the trunk is huge'],
      ['luke', "I'll bring the camp stove and the good coffee"],
      ['priya', 'Someone needs to handle groceries. I nominate Jordan.'],
      ['jordan', 'I accept, but we are eating tacos at least once'],
      ['maya', 'Non-negotiable honestly'],
      ['priya', "Here's the plan so far:\n\nFriday: leave at 3, dinner in Monterey\nSaturday: McWay Falls, then the Pfeiffer Beach sunset\nSunday: slow breakfast, drive home"],
      ['jordan', 'Can we add a hike on Saturday morning? The Ewoldsen trail is supposed to be great.'],
      ['priya', 'Added!'],
    ],
  });

  await room(u, {
    alias: 'design-crit',
    creator: 'alex',
    name: 'Design Crit',
    topic: 'Weekly critique, Wednesdays at 2',
    members: ['luke', 'priya', 'sam'],
    script: [
      ['alex', 'Posting the new onboarding flow for tomorrow. Three screens, the middle one is the one I am least sure about.'],
      ['priya', 'The permission prompt on screen two feels early. Could it wait until they try to use the feature?'],
      ['sam', 'Agree. Asking for notifications before they have sent a message is a hard sell.'],
      ['luke', 'Screen three is lovely though. The type scale works really well.'],
      ['alex', 'Thanks! I will move the prompt and bring both versions.'],
      ['priya', mentioningLuke('{luke}, could you check the contrast on screen three in dark mode? The gray labels look faint to me.')],
    ],
  });

  await room(u, {
    alias: 'book-club',
    creator: 'jordan',
    name: 'Book Club',
    topic: 'This month: The Left Hand of Darkness',
    members: ['luke', 'maya', 'priya', 'alex', 'sam'],
    script: [
      ['jordan', 'Reminder: we meet on the 30th. Chapters 1 to 10 for this one.'],
      ['alex', 'I am only on chapter 4, the calendar system is breaking my brain'],
      ['maya', 'It clicks around chapter 6, stick with it'],
      ['priya', 'The chapter with the ice crossing is one of my favorite things ever written'],
      ['sam', 'No spoilers!!'],
      ['priya', 'That was not a spoiler, it is in the blurb 😄'],
      ['maya', mentioningLuke('{luke} you finished it last week, was the ending worth the wait?')],
      ['jordan', { body: '@room we are meeting at the café on Elm Street this time, not the library.', 'm.mentions': { room: true } }],
    ],
  });

  // A pending invite, so the invite state has something to show.
  await room(u, {
    alias: 'garden-club',
    creator: 'alex',
    name: 'Community Garden',
    topic: 'Plot 14 and friends',
    members: [],
    invitesOnly: ['luke'],
    script: [['alex', 'Welcome! Watering rota is pinned below.']],
  });

  // Threads, a mention of Luke, rich formatting and a pinned message.
  await room(u, {
    alias: 'launch-planning',
    creator: 'alex',
    name: 'Launch Planning',
    topic: 'Xenia 1.0, shipping October 20',
    members: ['luke', 'maya', 'sam', 'priya'],
    script: async (roomId) => {
      await say(u.alex, roomId, "Morning all! Xenia 1.0 ships October 20. Let's keep everything launch related in here instead of five different DMs.");

      const checklist = await say(u.alex, roomId, {
        body: [
          '**Launch checklist** for *October 20*:',
          '',
          '- Final build submitted to App Review by `Oct 13`',
          '- Release notes approved by the whole team',
          '- Press kit live on the website',
          '',
          'Full timeline: https://xenia.example.com/launch',
        ].join('\n'),
        format: 'org.matrix.custom.html',
        formatted_body:
          '<strong>Launch checklist</strong> for <em>October 20</em>:' +
          '<ul><li>Final build submitted to App Review by <code>Oct 13</code></li>' +
          '<li>Release notes approved by the whole team</li>' +
          '<li>Press kit live on the website</li></ul>' +
          'Full timeline in the <a href="https://xenia.example.com/launch">launch doc</a>.',
      });

      const screenshots = await say(u.priya, roomId, "Where are we on the App Store screenshots? I'd love to lock them by Friday.");
      await reply(u.alex, roomId, screenshots, 'Five of the six are done. The dark mode one still looks a bit muddy.');
      await reply(u.luke, roomId, screenshots, 'I can reshoot that one tonight with the new wallpaper.');
      await reply(u.priya, roomId, screenshots, 'Amazing, thank you. Can you export at 1320 by 2868 so we cover the big phones?');
      await reply(u.luke, roomId, screenshots, "Will do. I'll drop them in the shared folder before bed.");
      await reply(u.alex, roomId, screenshots, 'Legend.');

      const feedback = await say(u.sam, roomId, 'Beta feedback roundup: 212 responses so far. The top request by a mile is message search.');
      await reply(u.maya, roomId, feedback, 'Search is already on the 1.1 list. Should we say that in the release notes?');
      await reply(u.luke, roomId, feedback, "Yes, let's be upfront about it. People are kinder when they know it's coming.");
      await reply(u.sam, roomId, feedback, 'Second most requested was a compact layout, which surprised me.');
      await reply(u.priya, roomId, feedback, 'Not surprised at all, the Mac folks have wanted that since the very first build.');
      await reply(u.sam, roomId, feedback, 'Fair! Adding both to the notes draft.');

      const pressKit = await say(u.luke, roomId, 'Press kit is up on the site. It just needs the final icon.');
      await reply(u.alex, roomId, pressKit, "Final icon lands Wednesday, I'll swap it in myself.");

      await say(u.priya, roomId, 'Launch day plan: we go live at 9am Pacific, then pastries in the office at 10.');
      await say(u.sam, roomId, 'Count me in for pastries. Especially the almond ones.');

      await say(u.maya, roomId, {
        body: 'Luke, can you review the release notes today?',
        format: 'org.matrix.custom.html',
        formatted_body: '<a href="https://matrix.to/#/@luke:localhost">Luke</a>, can you review the release notes today?',
        'm.mentions': { user_ids: ['@luke:localhost'] },
      });

      // Alex created the room, so has power level 100 and can pin.
      await setState(u.alex, roomId, 'm.room.pinned_events', { pinned: [checklist] });
    },
  });

  // A long history, for pagination and day dividers.
  await room(u, {
    alias: 'photo-walks',
    creator: 'jordan',
    name: 'Saturday Photo Walks',
    topic: 'Early starts, good light, better coffee',
    members: ['luke', 'alex', 'priya'],
    script: PHOTO_WALKS,
  });

  // A very long history (400 messages), for scrolling far back and for searching words that
  // this device has never downloaded ("sourdough" is only in the oldest messages).
  await room(u, {
    alias: 'coffee-chat',
    creator: 'maya',
    name: 'Coffee Chat',
    topic: 'Beans, brews and everything in between',
    members: ['luke', 'sam', 'jordan'],
    script: coffeeChat(),
  });

  // Public rooms Luke isn't in, so the room directory has something to browse and join. They're
  // listed on every run, so rooms created before listing worked get listed too.
  const community = await room(u, {
    alias: 'xenia-community',
    creator: 'alex',
    name: 'Xenia Community',
    topic: 'Say hi, share tips, report bugs',
    members: ['jordan', 'maya'],
    isPublic: true,
    script: [
      ['alex', "Welcome to the Xenia community room! Say hi and tell us what you're using Xenia for."],
      ['jordan', "Hi all! I've been on the beta on my Mac for a week and I'm loving it so far."],
      ['maya', 'Tip: Command K jumps to any room. It took me way too long to find that.'],
      ['alex', "If you spot a bug, post it here with your app version and we'll take a look."],
      ['jordan', 'Found one: the unread badge sometimes sticks around after I read a room on my phone.'],
      ['alex', 'Thanks Jordan, I can reproduce that. The fix is going into the next build.'],
    ],
  });

  const design = await room(u, {
    alias: 'matrix-design',
    creator: 'priya',
    name: 'Matrix Design',
    topic: 'Interfaces for the open web',
    members: ['sam'],
    isPublic: true,
    script: [
      ['priya', 'Starting this room for anyone designing Matrix clients. Share work in progress, ask questions, be kind.'],
      ['sam', 'Love this. First question: how are people showing threads on small screens?'],
      ['priya', 'I like a side panel on desktop and a full screen push on phones. It keeps the main timeline calm.'],
      ['sam', "That's where we landed too. Read receipts next, those are a whole other puzzle."],
    ],
  });
  await listPublicly(u.alex, community, 'xenia-community');
  await listPublicly(u.priya, design, 'matrix-design');

  // Ends on a question from Alex, so the DM has something waiting for a reply.
  await room(u, {
    alias: 'dm-luke-alex',
    creator: 'alex',
    members: ['luke'],
    isDirect: true,
    script: [
      ['alex', 'Hey! Are you around this weekend?'],
      ['luke', 'Mostly, why?'],
      ['alex', 'I found a tiny ramen place near the pier. They only open on Saturday nights.'],
      ['luke', 'Say no more'],
      ['alex', 'Is 7 too early for you, or should I book for 7:30?'],
    ],
  });

  await room(u, {
    alias: 'dm-luke-christopher',
    creator: 'christopher',
    members: ['luke'],
    isDirect: true,
    script: [
      ['christopher', 'Hi Luke, Christopher from the Thursday meetup. Your talk on offline sync was fantastic!'],
      ['luke', "Thank you, that's really kind! Happy to send over the slides."],
    ],
  });

  console.log(`Seeded ${HOMESERVER}. Sign in as @luke:localhost with the password in this script.`);
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
