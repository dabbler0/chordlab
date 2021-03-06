pcm = require 'pcm'
windowing = require 'fft-windowing'
dsp = require 'digitalsignals'
numeric = require 'numeric'
helper = require './helper.coffee'
chords = require './parse.coffee'

MIDI_MIN = 21
MIDI_MAX = 92

# SETION 0: METADATA
# ==================

# Audio context
class AudioContext
  constructor: (@rate, @size, @hop) ->
    @fft = new dsp.FFT @size, @rate

  timeForFrame: (i) -> i * @hop / @rate


# SECTION 1: FILTERBANKS
# ======================

# Tone profiles
# -------------
# A tone profile at given frequencies x_1...x_n is the FFT of a Hamming-windowed
# wave generated by sum(sin(2pi * x_i * x/ RATE)).
generateToneProfile = (freqs, context) ->
  wave = new Array context.size
  for i in [0...context.size]
    wave[i] = 0
    for freq, j in freqs
      wave[i] += Math.sin(2 * Math.PI * freq * i / context.rate) * 0.9 ** j

  wave = windowing.hamming wave

  context.fft.forward wave

  profile = new Array context.size / 2
  for i in [0...context.size / 2]
    profile[i] = context.fft.spectrum[i]

  return profile

getSemitone = (midi) -> 440 * 2 ** ((midi - 69) / 12)

# Filterbanks
# -----------
# Filterbanks are collections of tone profiles that can be multiplied
# by an FFT matrix to yield a salience matrix. This multiplication makes
# sense because it is the same as finding cosine similarities if the matrices
# are normalized.
SMOOTHING_WINDOW_WIDTH = 3
class CosineFilterbank
  constructor: (@profile) ->
    for row, i in @profile
      @profile[i] = helper.normalize row

  apply: (frames) ->
    salience = numeric.transpose numeric.dot(@profile, frames)
    # Smooth out the chromagram to only include those
    # outside one standard deviation from normal.
    for row in salience
      for note, i in row
        localSample = row[Math.max(0, i - SMOOTHING_WINDOW_WIDTH)..Math.min(row.length - 1, i + SMOOTHING_WINDOW_WIDTH)]
        mean = helper.mean(localSample)
        variance = helper.variance(localSample, mean)
        if row[i] < mean + variance
          row[i] = 0

    return salience

class FundamentalCosineFilterbank extends CosineFilterbank
  constructor: (min, max, @context) ->
    @profile = []
    for tone in [min * 3..max * 3]
      @profile.push(
        generateToneProfile(
          [getSemitone(tone / 3)],
          @context
        )
      )
    super @profile

class HarmonicCosineFilterbank extends CosineFilterbank
  constructor: (min, max, @context) ->
    @profile = []
    for tone in [min * 3..max * 3]
      @profile.push(
        generateToneProfile(
          (getSemitone(tone / 3) * i for i in [1..4]),
          @context
        )
      )
    super @profile

# SECTION 2: FFT
# ==============

# getFrames
# ---------
# A simple wrapper for `pcm.getPcmData` that divides the sound up into frames.
getFrames = (file, context, cb) ->
  frames = []
  currentFrame = []

  pcm.getPcmData(
    file,
    {stereo: false, sampleRate: context.sampleRate},
    ((sample, channel) ->
      if channel is 0
        if currentFrame.length is context.size
          frames.push currentFrame
          currentFrame = []
        currentFrame.push sample
    ),
    ((err, output) ->
      cb frames
    )
  )

# STFT
# ----
# Transform a set of frames into an STFT matrix
getSTFT = (frames, context) ->
  resultMatrix = []
  for row, i in frames
    context.fft.forward row
    spectrum = []
    for i in [0...context.size / 2]
      spectrum[i] = context.fft.spectrum[i]
    resultMatrix.push spectrum

  # We want the result matrix transposed, so that
  # we can properly multiply it with the frequency profiles.
  return numeric.transpose resultMatrix

# SECTION THREE: HIDDEN MARKOV MODEL
# =============


# Gaussian
# --------
# Simple function to generate gaussian (log) pdfs
gaussian = ({n, mu, sigma}) ->
  try
    constant = Math.log(
      (2 * Math.PI) ** (-n / 2) *
      numeric.det(sigma) ** (-1/2)
    )

    inverse = numeric.inv(sigma)

    return (x) ->
      residual = numeric.sub(x, mu)
      return constant + 1/2 * numeric.dot(numeric.dot(residual, inverse), residual)
  catch
    return ->
      -Infinity

# getGaussianParameters
# ---------------------
# Estimate the mean and covariance matrices
# for a data set.
getGaussianParameters = (n, vectors) ->
  # Means
  mu = (0 for [0...n])
  for vector in vectors
    for el, i in vector
      mu[i] += el / vectors.length

  sigma = ((0 for el in mu) for el in mu)
  # Variance/covariance
  for vector in vectors
    for a, i in vector
      for b, j in vector
        sigma[i][j] += (a - mu[i]) * (b - mu[j]) / (vectors.length - 1)

  return {n, mu, sigma}

# GaussianHMM
# -----------------
#
# Trainer
# In this model we assume that the transition and emission probabilities are
# both multivariate gaussians.
class GaussianHMMTrainer
  constructor: (@n, @k) ->
    @markov = ((0.1 for [0...@n]) for [0...@n]) # Start with everything as a way of lazy smoothing TODO held out
    @vectorCategories = ([] for [0...@n])

    @last = 0

  feed: (chroma) ->
    @vectorCategories[chroma.chord].push chroma.chroma
    @markov[@last][chroma.chord] += 1
    @last = chroma.chord

  generate: ->
    # Replace markov model with log probabilities
    generatedMarkov = []
    for row, i in @markov
      generatedMarkov.push helper.additiveNormalize(row).map((x) -> Math.log(x))

    gaussianPDF = @vectorCategories.map((category) => gaussian(getGaussianParameters(@k, category)))

    return new GaussianHMM @n, generatedMarkov, gaussianPDF

# Estimators
# This first one is a generator class for GaussianHMMState
class GaussianHMM
  constructor: (@n, @markov, @gaussians) ->

  createState: -> new GaussianHMMState @n, @markov, @gaussians

  estimate: (sequence) ->
    state = @createState()

    for el, i in sequence
      state.feed el

    return state.best()

# GaussianHMMState
# The one that actually does the DP and estimation and stuff.
class GaussianHMMState
  constructor: (@n, @markov, @gaussians) ->
    @probs = (0 for [0...@n])
    @lists = (helper.llist(i, null) for i in [0...@n])

  feed: (chroma) ->
    newProbs = []
    newLists = []

    # HMM DP transition
    for next in [0...@n]
      emissionProbability = @gaussians[next](chroma)

      best = null; max = -Infinity
      for last in [0...@n]
        prob = @probs[last] + @markov[last][next] + emissionProbability
        if prob > max
          max = prob; best = last

      newProbs[next] = max
      newLists[next] = helper.llist(next, @lists[best])

    @probs = newProbs
    @lists = newLists

    return

  best: ->
    best = null; max = -Infinity
    for el, i in @probs
      ###
      if el > max
        max = el
        best = @lists[i]
      ###
      if el > -Infinity
        console.log el, @lists[i].toArray().join ' '

class ChromaNote
  constructor: (@chord, @chroma) ->

# SECTION INFINITY: Actual runtime stuff.
# =======================================

# Generate the global audio context with the numbers
# we'll be using.
GLOBAL_AUDIO_CONTEXT = new AudioContext 11025, 4096, 512

FUNDAMENTAL_PROFILE = new FundamentalCosineFilterbank(
  MIDI_MIN,
  MIDI_MAX,
  GLOBAL_AUDIO_CONTEXT
)

HARMONIC_PROFILE = new HarmonicCosineFilterbank(
  MIDI_MIN,
  MIDI_MAX,
  GLOBAL_AUDIO_CONTEXT
)

applySemitoneFilter = (matrix, points) ->
  result = []
  for row, i in matrix
    result.push newRow = (0 for [0...12])
    for el, j in row
      if points[0] <= j < points[1]
        newRow[j % 12] += el * ((j - points[0]) / (points[1] - points[0]))
      else if points[1] <= j < points[2]
        newRow[j % 12] += el
      else if points[2] <= j < points[3]
        newRow[j % 12] += el * ((points[3] - j) / (points[3] - points[2]))

  return result

BASS_FILTER = [0, 0, 24, 48]
TREBLE_FILTER = [24, 48, 72, 72]
WIDE_FILTER = [0, 0, 72, 72]

# PART ONE HALF SOMETHING: CHORD MAPPINGS
# ---------------------------------------
BASES = [
  ['A'],
  ['A#', 'Bb'],
  ['B', 'Cb'],
  ['C'],
  ['C#', 'Db'],
  ['D'],
  ['D#', 'Eb'],
  ['E', 'Fb'],
  ['F'],
  ['F#', 'Gb'],
  ['G'],
  ['G#', 'Ab']
]

QUALITIES = [
  ['maj'],
  ['min'],
  ['dim'],
  ['aug'],
  ['maj7'],
  ['7'],
  ['dim7'],
  ['hdim7'],
  ['minmaj7'],
  ['maj6'],
  ['min6'],
  ['9'],
  ['maj9'],
  ['min9'],
  ['sus2'],
  ['sus4']
]

CHORD_NUMBERS = {'N': 0}

# Generate all possible chord permutations
NUMBER_OF_CHORDS = 1
for baseSet, i in BASES
  for qualitySet, j in QUALITIES
    for base in baseSet
      for quality in qualitySet
        CHORD_NUMBERS[base + ':' + quality] = NUMBER_OF_CHORDS
        if quality is 'maj' then CHORD_NUMBERS[base] = NUMBER_OF_CHORDS
    NUMBER_OF_CHORDS += 1

numberForChord = (chord) ->
  CHORD_NUMBERS[chord.split('(')[0]] ? 0

# INTERMISSION OVER
# -----------------
getFrames(
  'audio/01_-_Please_Please_Me/14 Twist And Shout.mp3',
  GLOBAL_AUDIO_CONTEXT,
  (frames) ->
    console.log 'got frames'
    stft = getSTFT frames, GLOBAL_AUDIO_CONTEXT

    console.log 'did stft'
    console.log 'applying profiles'
    fundamentalProfile = FUNDAMENTAL_PROFILE.apply stft
    console.log 'applied fundamental'
    harmonicProfile = HARMONIC_PROFILE.apply stft

    console.log 'done'

    preliminarySalience = helper.pointwiseMultiply fundamentalProfile, harmonicProfile

    #console.log helper.printMatrix numeric.transpose preliminarySalience

    # Tuning and semitone reduction
    average = preliminarySalience.reduce((a, b) -> a.map((x, i) -> x + b[i]))
    bins  = [0, 0, 0]
    for el, i in average
      bins[i % 3] += el

    maxBin = 0; best = 0
    for el, i in bins
      if el > best
        maxBin = i; best = el

    salience = preliminarySalience.map (row, t) ->
      semitoneRow = (0 for [21..92])
      for el, i in row
        semitoneRow[Math.floor((i - (i % 3 - maxBin)) / 3)] += el

      return semitoneRow

    bass = applySemitoneFilter salience, BASS_FILTER
    treble = applySemitoneFilter salience, TREBLE_FILTER
    wide = applySemitoneFilter salience, WIDE_FILTER

    trainingData = wide.map (x, i) ->
      new ChromaNote(
        numberForChord(chords.lookup(GLOBAL_AUDIO_CONTEXT.timeForFrame(i))),
        x
      )

    console.log 'feeding'
    trainer = new GaussianHMMTrainer NUMBER_OF_CHORDS, 12
    trainer.feed el for el in trainingData

    console.log 'Fed. Generating...'

    estimator = trainer.generate()

    console.log 'Generated.'

    console.log helper.printMatrix estimator.markov

    result = estimator.estimate(wide)

    console.log 'Estimated. Self-application yields:'

    console.log result.join ' '

    ###
    Loggy loggy stuff stuff

    console.log 'CHORDS:'
    timeJoinery = []
    joinery = []
    trebleAvgs = {}
    for row, i in treble
      timeJoinery.push GLOBAL_AUDIO_CONTEXT.timeForFrame(i).toFixed(6)
      joinery.push chord = chords.lookup GLOBAL_AUDIO_CONTEXT.timeForFrame i

      trebleAvgs[chord] ?= (0 for [0...12])
      for el, j in row
        trebleAvgs[chord][j] += el

    console.log '\t' + timeJoinery.join '\t'
    console.log '\t' + joinery.join '\t\t'

    for x in [treble, bass]
      x.unshift CHORDNAMES = [
        'A'
        'A#'
        'B'
        'C'
        'C#'
        'D'
        'D#'
        'E'
        'E#'
        'F'
        'G'
        'G#'
      ]


    console.log 'BASS:'
    console.log '====='
    console.log helper.printMatrix numeric.transpose bass

    console.log 'TREBLE:'
    console.log '======='
    console.log helper.printMatrix numeric.transpose treble

    console.log 'CHORD TREBLE AVGS:'
    console.log '=================='
    console.log '\t' + CHORDNAMES.join('\t\t')
    for key, val of trebleAvgs
      console.log key + '\t' + val.map((x) -> x.toFixed(6)).join('\t')
    ###
)

#console.log FUNDAMENTAL_PROFILE.profile[48]
