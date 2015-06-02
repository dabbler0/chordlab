numeric = require 'numeric'

exports.sum = (vector) ->
  vector.reduce((a, b) -> a + b)

exports.additiveNormalize = (vector) ->
  sum = exports.sum vector
  vector.map((x) -> x / sum)

exports.mag = (vector) ->
  Math.sqrt numeric.dot(vector, vector)

exports.normalize = (vector) ->
  numeric.dot(vector, 1 / exports.mag(vector))

exports.printMatrix = (matrix) ->
  matrix.map((x) -> x.map((y) -> if (typeof y) is 'number' then y.toFixed(6) else y).join('\t')).join('\n')

exports.mean = (vector) ->
  vector.reduce((a, b) -> a + b) / vector.length

exports.variance = (vector, mean) ->
  Math.sqrt(
    vector
      .map((x) -> (x - mean) ** 2)
      .reduce((a, b) -> a + b) / vector.length)

exports.pointwiseMultiply = (a, b) ->
  result = []
  for row, i in a
    result[i] = []
    for el, j in row
      result[i][j] = a[i][j] * b[i][j]
  return result

class LinkedList
  constructor: (@data, @tail) ->

  toArray: ->
    arr = []
    head = @
    while head?
      arr.unshift head.data
      head = head.tail

    return arr

exports.llist = (data, tail) -> new LinkedList data, tail
