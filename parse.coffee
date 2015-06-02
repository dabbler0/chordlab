fs = require 'fs'

lines = fs.readFileSync('chordlab/The Beatles/01_-_Please_Please_Me/14_-_Twist_And_Shout.lab').toString().split('\n')

chords = []

for line in lines
  [start, end, chord] = line.split(' ')
  start = Number start
  end = Number end

  chords.push {start, end, chord}

exports.lookup = lookup = (time) ->
  for el, i in chords
    if el.end > time >= el.start
      return el.chord
