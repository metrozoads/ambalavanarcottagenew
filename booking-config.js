/* =====================================================================
   SRI AMBALAVANAR COTTAGE · BOOKING SETTINGS
   Edit only this file to change rates, rooms, UPI or the database link.
   ===================================================================== */
window.SAC = {
  /* --- Live vacancy + room lock (Supabase) ---------------------------
     Leave both empty = DEMO MODE: booking works, but the room lock is kept
     only in the guest's own browser and the cottage does not see it.
     Fill both after running supabase-setup.sql (see SETUP-BOOKING.txt). */
  supabaseUrl: "",          // e.g. "https://abcdxyz.supabase.co"
  supabaseKey: "",          // the "anon public" key from Supabase > Project Settings > API

  /* --- Payment ------------------------------------------------------- */
  upiId: "metrotamilchannel-3@okicici",
  upiName: "Sri Ambalavanar Cottage",
  holdMinutes: 10,          // how long a room stays locked while the guest pays

  /* --- Cottage details on the GST invoice ----------------------------- */
  business: {
    name: "Sri Ambalavanar Cottage",
    legalName: "Meena Anandhakumar",
    gstin: "33EDFPM7582D1ZG",
    stateCode: "33",
    stateName: "Tamil Nadu",
    address1: "No 17/1, 17, Mayuranathar Sannathi,",
    address2: "Near Mayuranathar Temple, Mayiladuthurai, Tamil Nadu 609001",
    phone: "+91 90031 97704",
    email: "sriambalavanarcottage@gmail.com",
    whatsapp: "919003197704"
  },
  gstRate: 5,               // % (CGST half + SGST half). Rates below already INCLUDE GST.
  sac: "996311",

  /* --- Rates per night, GST included --------------------------------- */
  types: {
    D: { en: "Double", ta: "இரட்டை", ac: 2100, nonac: 1600, adults: 2, beds: { en: "Double bed", ta: "இரட்டைக் கட்டில்" }, kit: 2, photo: "room-twin.jpg" },
    T: { en: "Triple", ta: "மூவர்",  ac: 3150, nonac: 2650, adults: 3, beds: { en: "3 beds", ta: "3 கட்டில்கள்" }, kit: 3, photo: "room-ac.jpg" },
    S: { en: "Single", ta: "ஒற்றை",  ac: 1600, nonac: 1050, adults: 1, beds: { en: "Single bed", ta: "ஒற்றைக் கட்டில்" }, kit: 1, photo: "room-tv.jpg" }
  },
  extraBed: 500,            // per bed per night, GST included
  maxExtraBeds: 1,
  childFreeBelow: 12,

  /* --- Floor plan ------------------------------------------------------
     Rooms are drawn top to bottom; the entrance is at the bottom.
     Change left/right lists if the real building is different. */
  floors: [
    { id: "G", en: "Ground floor", ta: "தரைத் தளம்", left: ["G5","G4","G3","G2","G1"], right: ["G6","G7","G8","G9","G10"], end: [] },
    { id: "F", en: "First floor",  ta: "முதல் தளம்", left: ["F6","F5","F4","F3","F2","F1"], right: ["F7","F8","F9","F10","F11","F12"], end: ["F13"] }
  ],
  roomType: { G1: "T", F1: "T", F13: "S" }   // every other room is Double ("D")
};

window.SAC.typeOf = function (room) { return window.SAC.roomType[room] || "D"; };
window.SAC.allRooms = function () {
  return window.SAC.floors.flatMap(function (f) { return f.end.concat(f.left, f.right); });
};

/* Small client for the Supabase database functions (no library needed). */
window.SAC.live = function () { return !!(window.SAC.supabaseUrl && window.SAC.supabaseKey); };
window.SAC.rpc = function (fn, args) {
  var s = window.SAC;
  return fetch(s.supabaseUrl.replace(/\/$/, "") + "/rest/v1/rpc/" + fn, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: s.supabaseKey, Authorization: "Bearer " + s.supabaseKey },
    body: JSON.stringify(args || {})
  }).then(function (r) {
    return r.json().catch(function () { return null; }).then(function (j) {
      if (!r.ok) { var e = new Error((j && (j.message || j.hint)) || ("HTTP " + r.status)); e.code = j && j.message; throw e; }
      return j;
    });
  });
};
