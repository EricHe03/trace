//
//  HPACKHuffmanData.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation

// MARK: - Huffman Decode Structures

/// Represents a node in the Huffman decode table.
public struct HuffmanDecodeNode: Sendable {
    public let fstate: UInt16
    public let sym: UInt8

    public var hasSymbol: Bool {
        (fstate & huffSymMask) != 0
    }

    public var isAccepted: Bool {
        (fstate & huffAcceptedMask) != 0
    }

    public var nextState: Int {
        Int(fstate & 0x1FF)
    }
}

let huffAcceptedMask: UInt16 = 1 << 14
let huffSymMask: UInt16 = 1 << 15

// MARK: - Huffman Decode Table

@available(macOS 11.0, iOS 14.0, *)
public enum HuffmanDecodeTable {
    // Rule: Each node is packed as big-endian UInt16 (fstate) + UInt8 (sym).
    private static let encodedTableBase64 = """
    AAQAAAUAAAcAAAgAAAsAAAwAABAAABMAABkAABwAACAAACMAACoAADEAADkAQEAAwAAwwAAxwAAy
    wABhwABjwABlwABpwABvwABzwAB0AA0AAA4AABEAABIAABQAABUAgAEwwBYwgAExwBYxgAEywBYy
    gAFhwBZhgAFjwBZjgAFlwBZlgAFpwBZpgAFvwBZvgAIwgAkwgBcwwCgwgAIxgAkxgBcxwCgxgAIy
    gAkygBcywCgygAJhgAlhgBdhwChhgAMwgAYwgAowgA8wgBgwgB8wgCkwwDgwgAMxgAYxgAoxgA8x
    gBgxgB8xgCkxwDgxgAMygAYygAoygA8ygBgygB8ygCkywDgygANhgAZhgAphgA9hgBhhgB9hgClh
    wDhhgAJjgAljgBdjwChjgAJlgAllgBdlwChlgAJpgAlpgBdpwChpgAJvgAlvgBdvwChvgANjgAZj
    gApjgA9jgBhjgB9jgCljwDhjgANlgAZlgAplgA9lgBhlgB9lgCllwDhlgANpgAZpgAppgA9pgBhp
    gB9pgClpwDhpgANvgAZvgApvgA9vgBhvgB9vgClvwDhvgAFzwBZzgAF0wBZ0wAAgwAAlwAAtwAAu
    wAAvwAAzwAA0wAA1wAA2wAA3wAA4wAA5gAJzgAlzgBdzwChzgAJ0gAl0gBd0wCh0gAEgwBYggAEl
    wBYlgAEtwBYtgAEuwBYugANzgAZzgApzgA9zgBhzgB9zgClzwDhzgAN0gAZ0gAp0gA90gBh0gB90
    gCl0wDh0gAIggAkggBcgwCgggAIlgAklgBclwCglgAItgAktgBctwCgtgAIugAkugBcuwCgugAMg
    gAYggAoggA8ggBgggB8ggCkgwDgggAMlgAYlgAolgA8lgBglgB8lgCklwDglgAMtgAYtgAotgA8t
    gBgtgB8tgCktwDgtgAMugAYugAougA8ugBgugB8ugCkuwDgugAEvwBYvgAEzwBYzgAE0wBY0gAE1
    wBY1gAE2wBY2gAE3wBY3gAE4wBY4gAE5wBY5gAIvgAkvgBcvwCgvgAIzgAkzgBczwCgzgAI0gAk0
    gBc0wCg0gAI1gAk1gBc1wCg1gAMvgAYvgAovgA8vgBgvgB8vgCkvwDgvgAMzgAYzgAozgA8zgBgz
    gB8zgCkzwDgzgAM0gAY0gAo0gA80gBg0gB80gCk0wDg0gAM1gAY1gAo1gA81gBg1gB81gCk1wDg1
    gAI2gAk2gBc2wCg2gAI3gAk3gBc3wCg3gAI4gAk4gBc4wCg4gAI5gAk5gBc5wCg5gAM2gAY2gAo2
    gA82gBg2gB82gCk2wDg2gAM3gAY3gAo3gA83gBg3gB83gCk3wDg3gAM4gAY4gAo4gA84gBg4gB84
    gCk4wDg4gAM5gAY5gAo5gA85gBg5gB85gCk5wDg5ABoAABsAAB0AAB4AACEAACIAACQAACUAACsA
    AC4AADIAADUAADoAAD0AAEEAQEQAwAA9wABBwABfwABiwABkwABmwABnwABowABswABtwABuwABw
    wABywAB1ACYAACcAgAE9wBY9gAFBwBZBgAFfwBZfgAFiwBZigAFkwBZkgAFmwBZmgAFnwBZngAFo
    wBZogAI9gAk9gBc9wCg9gAJBgAlBgBdBwChBgAJfgAlfgBdfwChfgAJigAligBdiwChigAM9gAY9
    gAo9gA89gBg9gB89gCk9wDg9gANBgAZBgApBgA9BgBhBgB9BgClBwDhBgANfgAZfgApfgA9fgBhf
    gB9fgClfwDhfgANigAZigApigA9igBhigB9igCliwDhigAJkgAlkgBdkwChkgAJmgAlmgBdmwChm
    gAJngAlngBdnwChngAJogAlogBdowChogANkgAZkgApkgA9kgBhkgB9kgClkwDhkgANmgAZmgApm
    gA9mgBhmgB9mgClmwDhmgANngAZngApngA9ngBhngB9ngClnwDhngANogAZogApogA9ogBhogB9o
    gClowDhogAFswBZsgAFtwBZtgAFuwBZugAFwwBZwgAFywBZygAF1wBZ1wAA6wABCwABDwABEgAJs
    gAlsgBdswChsgAJtgAltgBdtwChtgAJugAlugBduwChugAJwgAlwgBdwwChwgANsgAZsgApsgA9s
    gBhsgB9sgClswDhsgANtgAZtgAptgA9tgBhtgB9tgCltwDhtgANugAZugApugA9ugBhugB9ugClu
    wDhugANwgAZwgApwgA9wgBhwgB9wgClwwDhwgAJygAlygBdywChygAJ1gAl1gBd1wCh1gAE6wBY6
    gAFCwBZCgAFDwBZDgAFEwBZEgANygAZygApygA9ygBhygB9ygClywDhygAN1gAZ1gAp1gA91gBh1
    gB91gCl1wDh1gAI6gAk6gBc6wCg6gAJCgAlCgBdCwChCgAJDgAlDgBdDwChDgAJEgAlEgBdEwChE
    gAM6gAY6gAo6gA86gBg6gB86gCk6wDg6gANCgAZCgApCgA9CgBhCgB9CgClCwDhCgANDgAZDgApD
    gA9DgBhDgB9DgClDwDhDgANEgAZEgApEgA9EgBhEgB9EgClEwDhEACwAAC0AAC8AADAAADMAADQA
    ADYAADcAADsAADwAAD4AAD8AAEIAAEMAAEUAQEgAwABFwABGwABHwABIwABJwABKwABLwABMwABN
    wABOwABPwABQwABRwABSwABTwABUgAFFwBZFgAFGwBZGgAFHwBZHgAFIwBZIgAFJwBZJgAFKwBZK
    gAFLwBZLgAFMwBZMgAJFgAlFgBdFwChFgAJGgAlGgBdGwChGgAJHgAlHgBdHwChHgAJIgAlIgBdI
    wChIgANFgAZFgApFgA9FgBhFgB9FgClFwDhFgANGgAZGgApGgA9GgBhGgB9GgClGwDhGgANHgAZH
    gApHgA9HgBhHgB9HgClHwDhHgANIgAZIgApIgA9IgBhIgB9IgClIwDhIgAJJgAlJgBdJwChJgAJK
    gAlKgBdKwChKgAJLgAlLgBdLwChLgAJMgAlMgBdMwChMgANJgAZJgApJgA9JgBhJgB9JgClJwDhJ
    gANKgAZKgApKgA9KgBhKgB9KgClKwDhKgANLgAZLgApLgA9LgBhLgB9LgClLwDhLgANMgAZMgApM
    gA9MgBhMgB9MgClMwDhMgAFNwBZNgAFOwBZOgAFPwBZPgAFQwBZQgAFRwBZRgAFSwBZSgAFTwBZT
    gAFUwBZUgAJNgAlNgBdNwChNgAJOgAlOgBdOwChOgAJPgAlPgBdPwChPgAJQgAlQgBdQwChQgANN
    gAZNgApNgA9NgBhNgB9NgClNwDhNgANOgAZOgApOgA9OgBhOgB9OgClOwDhOgANPgAZPgApPgA9P
    gBhPgB9PgClPwDhPgANQgAZQgApQgA9QgBhQgB9QgClQwDhQgAJRgAlRgBdRwChRgAJSgAlSgBdS
    wChSgAJTgAlTgBdTwChTgAJUgAlUgBdUwChUgANRgAZRgApRgA9RgBhRgB9RgClRwDhRgANSgAZS
    gApSgA9SgBhSgB9SgClSwDhSgANTgAZTgApTgA9TgBhTgB9TgClTwDhTgANUgAZUgApUgA9UgBhU
    gB9UgClUwDhUwABVwABWwABXwABZwABqwABrwABxwAB2wAB3wAB4wAB5wAB6AEYAAEcAAEkAQEoA
    gAFVwBZVgAFWwBZWgAFXwBZXgAFZwBZZgAFqwBZqgAFrwBZrgAFxwBZxgAF2wBZ2gAJVgAlVgBdV
    wChVgAJWgAlWgBdWwChWgAJXgAlXgBdXwChXgAJZgAlZgBdZwChZgANVgAZVgApVgA9VgBhVgB9V
    gClVwDhVgANWgAZWgApWgA9WgBhWgB9WgClWwDhWgANXgAZXgApXgA9XgBhXgB9XgClXwDhXgANZ
    gAZZgApZgA9ZgBhZgB9ZgClZwDhZgAJqgAlqgBdqwChqgAJrgAlrgBdrwChrgAJxgAlxgBdxwChx
    gAJ2gAl2gBd2wCh2gANqgAZqgApqgA9qgBhqgB9qgClqwDhqgANrgAZrgAprgA9rgBhrgB9rgClr
    wDhrgANxgAZxgApxgA9xgBhxgB9xgClxwDhxgAN2gAZ2gAp2gA92gBh2gB92gCl2wDh2gAF3wBZ3
    gAF4wBZ4gAF5wBZ5gAF6wBZ6wAAmwAAqwAAswAA7wABYwABaAEsAAE4AgAJ3gAl3gBd3wCh3gAJ4
    gAl4gBd4wCh4gAJ5gAl5gBd5wCh5gAJ6gAl6gBd6wCh6gAN3gAZ3gAp3gA93gBh3gB93gCl3wDh3
    gAN4gAZ4gAp4gA94gBh4gB94gCl4wDh4gAN5gAZ5gAp5gA95gBh5gB95gCl5wDh5gAN6gAZ6gAp6
    gA96gBh6gB96gCl6wDh6gAEmwBYmgAEqwBYqgAEswBYsgAE7wBY7gAFYwBZYgAFawBZaAEwAAE0A
    AE8AAFEAgAImgAkmgBcmwCgmgAIqgAkqgBcqwCgqgAIsgAksgBcswCgsgAI7gAk7gBc7wCg7gAMm
    gAYmgAomgA8mgBgmgB8mgCkmwDgmgAMqgAYqgAoqgA8qgBgqgB8qgCkqwDgqgAMsgAYsgAosgA8s
    gBgsgB8sgCkswDgsgAM7gAY7gAo7gA87gBg7gB87gCk7wDg7gAJYgAlYgBdYwChYgAJagAlagBda
    wChawAAhwAAiwAAowAApwAA/AFAAAFIAAFQAgANYgAZYgApYgA9YgBhYgB9YgClYwDhYgANagAZa
    gApagA9agBhagB9agClawDhagAEhwBYhgAEiwBYigAEowBYogAEpwBYpgAE/wBY/wAAnwAArwAB8
    AFMAAFUAAFgAgAIhgAkhgBchwCghgAIigAkigBciwCgigAIogAkogBcowCgogAIpgAkpgBcpwCgp
    gAMhgAYhgAohgA8hgBghgB8hgCkhwDghgAMigAYigAoigA8igBgigB8igCkiwDgigAMogAYogAoo
    gA8ogBgogB8ogCkowDgogAMpgAYpgAopgA8pgBgpgB8pgCkpwDgpgAI/gAk/gBc/wCg/gAEnwBYn
    gAErwBYrgAF8wBZ8wAAjwAA+AFYAAFcAAFkAAFoAgAM/gAY/gAo/gA8/gBg/gB8/gCk/wDg/gAIn
    gAkngBcnwCgngAIrgAkrgBcrwCgrgAMngAYngAongA8ngBgngB8ngCknwDgngAMrgAYrgAorgA8r
    gBgrgB8rgCkrwDgrgAJ8gAl8gBd8wCh8gAEjwBYjgAE+wBY+wAAAwAAkwABAwABbwABdwAB+AFsA
    AFwAgAN8gAZ8gAp8gA98gBh8gB98gCl8wDh8gAIjgAkjgBcjwCgjgAI+gAk+gBc+wCg+gAMjgAYj
    gAojgA8jgBgjgB8jgCkjwDgjgAM+gAY+gAo+gA8+gBg+gB8+gCk+wDg+gAEAwBYAgAEkwBYkgAFA
    wBZAgAFbwBZbgAFdwBZdgAF+wBZ+wABewAB9AF0AAF4AgAIAgAkAgBcAwCgAgAIkgAkkgBckwCgk
    gAJAgAlAgBdAwChAgAJbgAlbgBdbwChbgAMAgAYAgAoAgA8AgBgAgB8AgCkAwDgAgAMkgAYkgAok
    gA8kgBgkgB8kgCkkwDgkgANAgAZAgApAgA9AgBhAgB9AgClAwDhAgANbgAZbgApbgA9bgBhbgB9b
    gClbwDhbgAJdgAldgBddwChdgAJ+gAl+gBd+wCh+gAFewBZegAF9wBZ9wAA8wABgwAB7AF8AgANd
    gAZdgApdgA9dgBhdgB9dgCldwDhdgAN+gAZ+gAp+gA9+gBh+gB9+gCl+wDh+gAJegAlegBdewChe
    gAJ9gAl9gBd9wCh9gAE8wBY8gAFgwBZggAF7wBZ7AGAAAG4AgANegAZegApegA9egBhegB9egCle
    wDhegAN9gAZ9gAp9gA99gBh9gB99gCl9wDh9gAI8gAk8gBc8wCg8gAJggAlggBdgwChggAJ7gAl7
    gBd7wCh7AGEAAGUAAG8AAIUAgAM8gAY8gAo8gA88gBg8gB88gCk8wDg8gANggAZggApggA9ggBhg
    gB9ggClgwDhggAN7gAZ7gAp7gA97gBh7gB97gCl7wDh7AGIAAGMAAGYAAGkAAHAAAHcAAIYAAJkA
    wABcwADDwADQAGQAAGcAAGgAAGoAAGsAAHEAAHQAAHgAAH4AAIcAAI4AAJoAAKkAgAFcwBZcgAHD
    wBbDgAHQwBbQwACAwACCwACDwACiwAC4wADCwADgwADiAGwAAG0AgAJcgAlcgBdcwChcgALDgAnD
    gBfDwCjDgALQgAnQgBfQwCjQgAGAwBaAgAGCwBaCgANcgAZcgApcgA9cgBhcgB9cgClcwDhcgAPD
    gAbDgArDgA/DgBjDgB/DgCnDwDjDgAPQgAbQgArQgA/QgBjQgB/QgCnQwDjQgAKAgAmAgBeAwCiA
    gAKCgAmCgBeCwCiCgAOAgAaAgAqAgA+AgBiAgB+AgCmAwDiAgAOCgAaCgAqCgA+CgBiCgB+CgCmC
    wDiCgAGDwBaDgAGiwBaigAG4wBa4gAHCwBbCgAHgwBbggAHiwBbiwACZwAChwACnwACsgAKDgAmD
    gBeDwCiDgAKigAmigBeiwCiigAK4gAm4gBe4wCi4gALCgAnCgBfCwCjCgAODgAaDgAqDgA+DgBiD
    gB+DgCmDwDiDgAOigAaigAqigA+igBiigB+igCmiwDiigAO4gAa4gAq4gA+4gBi4gB+4gCm4wDi4
    gAPCgAbCgArCgA/CgBjCgB/CgCnCwDjCgALggAnggBfgwCjggALigAnigBfiwCjigAGZwBaZgAGh
    wBahgAGnwBangAGswBasgAPggAbggArggA/ggBjggB/ggCngwDjggAPigAbigArigA/igBjigB/i
    gCniwDjigAKZgAmZgBeZwCiZgAKhgAmhgBehwCihgAKngAmngBenwCingAKsgAmsgBeswCisgAOZ
    gAaZgAqZgA+ZgBiZgB+ZgCmZwDiZgAOhgAahgAqhgA+hgBihgB+hgCmhwDihgAOngAangAqngA+n
    gBingB+ngCmnwDingAOsgAasgAqsgA+sgBisgB+sgCmswDisAHIAAHMAAHUAAHYAAHkAAHsAAH8A
    AIIAAIgAAIsAAI8AAJIAAJsAAKIAAKoAALQAwACwwACxwACzwADRwADYwADZwADjwADlwADmAHoA
    AHwAAH0AAIAAAIEAAIMAAIQAgAGwwBawgAGxwBaxgAGzwBazgAHRwBbRgAHYwBbYgAHZwBbZgAHj
    wBbjgAHlwBblgAKwgAmwgBewwCiwgAKxgAmxgBexwCixgAKzgAmzgBezwCizgALRgAnRgBfRwCjR
    gAOwgAawgAqwgA+wgBiwgB+wgCmwwDiwgAOxgAaxgAqxgA+xgBixgB+xgCmxwDixgAOzgAazgAqz
    gA+zgBizgB+zgCmzwDizgAPRgAbRgArRgA/RgBjRgB/RgCnRwDjRgALYgAnYgBfYwCjYgALZgAnZ
    gBfZwCjZgALjgAnjgBfjwCjjgALlgAnlgBflwCjlgAPYgAbYgArYgA/YgBjYgB/YgCnYwDjYgAPZ
    gAbZgArZgA/ZgBjZgB/ZgCnZwDjZgAPjgAbjgArjgA/jgBjjgB/jgCnjwDjjgAPlgAblgArlgA/l
    gBjlgB/lgCnlwDjlgAHmwBbmwACBwACEwACFwACGwACIwACSwACawACcwACgwACjwACkwACpwACq
    wACtgALmgAnmgBfmwCjmgAGBwBaBgAGEwBaEgAGFwBaFgAGGwBaGgAGIwBaIgAGSwBaSgAPmgAbm
    gArmgA/mgBjmgB/mgCnmwDjmgAKBgAmBgBeBwCiBgAKEgAmEgBeEwCiEgAOBgAaBgAqBgA+BgBiB
    gB+BgCmBwDiBgAOEgAaEgAqEgA+EgBiEgB+EgCmEwDiEgAKFgAmFgBeFwCiFgAKGgAmGgBeGwCiG
    gAKIgAmIgBeIwCiIgAKSgAmSgBeSwCiSgAOFgAaFgAqFgA+FgBiFgB+FgCmFwDiFgAOGgAaGgAqG
    gA+GgBiGgB+GgCmGwDiGgAOIgAaIgAqIgA+IgBiIgB+IgCmIwDiIgAOSgAaSgAqSgA+SgBiSgB+S
    gCmSwDiSgAGawBaagAGcwBacgAGgwBaggAGjwBajgAGkwBakgAGpwBapgAGqwBaqgAGtwBatgAKa
    gAmagBeawCiagAKcgAmcgBecwCicgAKggAmggBegwCiggAKjgAmjgBejwCijgAOagAaagAqagA+a
    gBiagB+agCmawDiagAOcgAacgAqcgA+cgBicgB+cgCmcwDicgAOggAaggAqggA+ggBiggB+ggCmg
    wDiggAOjgAajgAqjgA+jgBijgB+jgCmjwDijgAKkgAmkgBekwCikgAKpgAmpgBepwCipgAKqgAmq
    gBeqwCiqgAKtgAmtgBetwCitgAOkgAakgAqkgA+kgBikgB+kgCmkwDikgAOpgAapgAqpgA+pgBip
    gB+pgCmpwDipgAOqgAaqgAqqgA+qgBiqgB+qgCmqwDiqgAOtgAatgAqtgA+tgBitgB+tgCmtwDit
    AIkAAIoAAIwAAI0AAJAAAJEAAJMAAJYAAJwAAJ8AAKMAAKYAAKsAAK4AALUAAL4AwACywAC1wAC5
    wAC6wAC7wAC9wAC+wADEwADGwADkwADowADpAJQAAJUAAJcAAJgAgAGywBaygAG1wBa1gAG5wBa5
    gAG6wBa6gAG7wBa7gAG9wBa9gAG+wBa+gAHEwBbEgAKygAmygBeywCiygAK1gAm1gBe1wCi1gAK5
    gAm5gBe5wCi5gAK6gAm6gBe6wCi6gAOygAaygAqygA+ygBiygB+ygCmywDiygAO1gAa1gAq1gA+1
    gBi1gB+1gCm1wDi1gAO5gAa5gAq5gA+5gBi5gB+5gCm5wDi5gAO6gAa6gAq6gA+6gBi6gB+6gCm6
    wDi6gAK7gAm7gBe7wCi7gAK9gAm9gBe9wCi9gAK+gAm+gBe+wCi+gALEgAnEgBfEwCjEgAO7gAa7
    gAq7gA+7gBi7gB+7gCm7wDi7gAO9gAa9gAq9gA+9gBi9gB+9gCm9wDi9gAO+gAa+gAq+gA++gBi+
    gB++gCm+wDi+gAPEgAbEgArEgA/EgBjEgB/EgCnEwDjEgAHGwBbGgAHkwBbkgAHowBbogAHpwBbp
    wAABwACHwACJwACKwACLwACMwACNwACPgALGgAnGgBfGwCjGgALkgAnkgBfkwCjkgALogAnogBfo
    wCjogALpgAnpgBfpwCjpgAPGgAbGgArGgA/GgBjGgB/GgCnGwDjGgAPkgAbkgArkgA/kgBjkgB/k
    gCnkwDjkgAPogAbogArogA/ogBjogB/ogCnowDjogAPpgAbpgArpgA/pgBjpgB/pgCnpwDjpgAEB
    wBYBgAGHwBaHgAGJwBaJgAGKwBaKgAGLwBaLgAGMwBaMgAGNwBaNgAGPwBaPgAIBgAkBgBcBwCgB
    gAKHgAmHgBeHwCiHgAKJgAmJgBeJwCiJgAKKgAmKgBeKwCiKgAMBgAYBgAoBgA8BgBgBgB8BgCkB
    wDgBgAOHgAaHgAqHgA+HgBiHgB+HgCmHwDiHgAOJgAaJgAqJgA+JgBiJgB+JgCmJwDiJgAOKgAaK
    gAqKgA+KgBiKgB+KgCmKwDiKgAKLgAmLgBeLwCiLgAKMgAmMgBeMwCiMgAKNgAmNgBeNwCiNgAKP
    gAmPgBePwCiPgAOLgAaLgAqLgA+LgBiLgB+LgCmLwDiLgAOMgAaMgAqMgA+MgBiMgB+MgCmMwDiM
    gAONgAaNgAqNgA+NgBiNgB+NgCmNwDiNgAOPgAaPgAqPgA+PgBiPgB+PgCmPwDiPAJ0AAJ4AAKAA
    AKEAAKQAAKUAAKcAAKgAAKwAAK0AAK8AALEAALYAALkAAL8AAM8AwACTwACVwACWwACXwACYwACb
    wACdwACewAClwACmwACowACuwACvwAC0wAC2wAC3gAGTwBaTgAGVwBaVgAGWwBaWgAGXwBaXgAGY
    wBaYgAGbwBabgAGdwBadgAGewBaegAKTgAmTgBeTwCiTgAKVgAmVgBeVwCiVgAKWgAmWgBeWwCiW
    gAKXgAmXgBeXwCiXgAOTgAaTgAqTgA+TgBiTgB+TgCmTwDiTgAOVgAaVgAqVgA+VgBiVgB+VgCmV
    wDiVgAOWgAaWgAqWgA+WgBiWgB+WgCmWwDiWgAOXgAaXgAqXgA+XgBiXgB+XgCmXwDiXgAKYgAmY
    gBeYwCiYgAKbgAmbgBebwCibgAKdgAmdgBedwCidgAKegAmegBeewCiegAOYgAaYgAqYgA+YgBiY
    gB+YgCmYwDiYgAObgAabgAqbgA+bgBibgB+bgCmbwDibgAOdgAadgAqdgA+dgBidgB+dgCmdwDid
    gAOegAaegAqegA+egBiegB+egCmewDiegAGlwBalgAGmwBamgAGowBaogAGuwBaugAGvwBavgAG0
    wBa0gAG2wBa2gAG3wBa3gAKlgAmlgBelwCilgAKmgAmmgBemwCimgAKogAmogBeowCiogAKugAmu
    gBeuwCiugAOlgAalgAqlgA+lgBilgB+lgCmlwDilgAOmgAamgAqmgA+mgBimgB+mgCmmwDimgAOo
    gAaogAqogA+ogBiogB+ogCmowDiogAOugAaugAqugA+ugBiugB+ugCmuwDiugAKvgAmvgBevwCiv
    gAK0gAm0gBe0wCi0gAK2gAm2gBe2wCi2gAK3gAm3gBe3wCi3gAOvgAavgAqvgA+vgBivgB+vgCmv
    wDivgAO0gAa0gAq0gA+0gBi0gB+0gCm0wDi0gAO2gAa2gAq2gA+2gBi2gB+2gCm2wDi2gAO3gAa3
    gAq3gA+3gBi3gB+3gCm3wDi3wAC8wAC/wADFwADnwADvALAAALIAALMAALcAALgAALoAALsAAMAA
    AMcAANAAAN8AgAG8wBa8gAG/wBa/gAHFwBbFgAHnwBbngAHvwBbvwAAJwACOwACQwACRwACUwACf
    gAK8gAm8gBe8wCi8gAK/gAm/gBe/wCi/gALFgAnFgBfFwCjFgALngAnngBfnwCjngAO8gAa8gAq8
    gA+8gBi8gB+8gCm8wDi8gAO/gAa/gAq/gA+/gBi/gB+/gCm/wDi/gAPFgAbFgArFgA/FgBjFgB/F
    gCnFwDjFgAPngAbngArngA/ngBjngB/ngCnnwDjngALvgAnvgBfvwCjvgAEJwBYJgAGOwBaOgAGQ
    wBaQgAGRwBaRgAGUwBaUgAGfwBafgAPvgAbvgArvgA/vgBjvgB/vgCnvwDjvgAIJgAkJgBcJwCgJ
    gAKOgAmOgBeOwCiOgAMJgAYJgAoJgA8JgBgJgB8JgCkJwDgJgAOOgAaOgAqOgA+OgBiOgB+OgCmO
    wDiOgAKQgAmQgBeQwCiQgAKRgAmRgBeRwCiRgAKUgAmUgBeUwCiUgAKfgAmfgBefwCifgAOQgAaQ
    gAqQgA+QgBiQgB+QgCmQwDiQgAORgAaRgAqRgA+RgBiRgB+RgCmRwDiRgAOUgAaUgAqUgA+UgBiU
    gB+UgCmUwDiUgAOfgAafgAqfgA+fgBifgB+fgCmfwDifwACrwADOwADXwADhwADswADtALwAAL0A
    AMEAAMQAAMgAAMsAANEAANgAAOAAAO4AgAGrwBargAHOwBbOgAHXwBbXgAHhwBbhgAHswBbsgAHt
    wBbtwADHwADPwADqwADrgAKrgAmrgBerwCirgALOgAnOgBfOwCjOgALXgAnXgBfXwCjXgALhgAnh
    gBfhwCjhgAOrgAargAqrgA+rgBirgB+rgCmrwDirgAPOgAbOgArOgA/OgBjOgB/OgCnOwDjOgAPX
    gAbXgArXgA/XgBjXgB/XgCnXwDjXgAPhgAbhgArhgA/hgBjhgB/hgCnhwDjhgALsgAnsgBfswCjs
    gALtgAntgBftwCjtgAHHwBbHgAHPwBbPgAHqwBbqgAHrwBbrgAPsgAbsgArsgA/sgBjsgB/sgCns
    wDjsgAPtgAbtgArtgA/tgBjtgB/tgCntwDjtgALHgAnHgBfHwCjHgALPgAnPgBfPwCjPgALqgAnq
    gBfqwCjqgALrgAnrgBfrwCjrgAPHgAbHgArHgA/HgBjHgB/HgCnHwDjHgAPPgAbPgArPgA/PgBjP
    gB/PgCnPwDjPgAPqgAbqgArqgA/qgBjqgB/qgCnqwDjqgAPrgAbrgArrgA/rgBjrgB/rgCnrwDjr
    AMIAAMMAAMUAAMYAAMkAAMoAAMwAAM0AANIAANUAANkAANwAAOEAAOcAAO8AAPYAwADAwADBwADI
    wADJwADKwADNwADSwADVwADawADbwADuwADwwADywADzwAD/AM4AgAHAwBbAgAHBwBbBgAHIwBbI
    gAHJwBbJgAHKwBbKgAHNwBbNgAHSwBbSgAHVwBbVgALAgAnAgBfAwCjAgALBgAnBgBfBwCjBgALI
    gAnIgBfIwCjIgALJgAnJgBfJwCjJgAPAgAbAgArAgA/AgBjAgB/AgCnAwDjAgAPBgAbBgArBgA/B
    gBjBgB/BgCnBwDjBgAPIgAbIgArIgA/IgBjIgB/IgCnIwDjIgAPJgAbJgArJgA/JgBjJgB/JgCnJ
    wDjJgALKgAnKgBfKwCjKgALNgAnNgBfNwCjNgALSgAnSgBfSwCjSgALVgAnVgBfVwCjVgAPKgAbK
    gArKgA/KgBjKgB/KgCnKwDjKgAPNgAbNgArNgA/NgBjNgB/NgCnNwDjNgAPSgAbSgArSgA/SgBjS
    gB/SgCnSwDjSgAPVgAbVgArVgA/VgBjVgB/VgCnVwDjVgAHawBbagAHbwBbbgAHuwBbugAHwwBbw
    gAHywBbygAHzwBbzgAH/wBb/wADLwADMgALagAnagBfawCjagALbgAnbgBfbwCjbgALugAnugBfu
    wCjugALwgAnwgBfwwCjwgAPagAbagAragA/agBjagB/agCnawDjagAPbgAbbgArbgA/bgBjbgB/b
    gCnbwDjbgAPugAbugArugA/ugBjugB/ugCnuwDjugAPwgAbwgArwgA/wgBjwgB/wgCnwwDjwgALy
    gAnygBfywCjygALzgAnzgBfzwCjzgAL/gAn/gBf/wCj/gAHLwBbLgAHMwBbMgAPygAbygArygA/y
    gBjygB/ygCnywDjygAPzgAbzgArzgA/zgBjzgB/zgCnzwDjzgAP/gAb/gAr/gA//gBj/gB//gCn/
    wDj/gALLgAnLgBfLwCjLgALMgAnMgBfMwCjMgAPLgAbLgArLgA/LgBjLgB/LgCnLwDjLgAPMgAbM
    gArMgA/MgBjMgB/MgCnMwDjMANMAANQAANYAANcAANoAANsAAN0AAN4AAOIAAOQAAOgAAOsAAPAA
    APMAAPcAAPoAwADTwADUwADWwADdwADewADfwADxwAD0wAD1wAD2wAD3wAD4wAD6wAD7wAD8wAD9
    gAHTwBbTgAHUwBbUgAHWwBbWgAHdwBbdgAHewBbegAHfwBbfgAHxwBbxgAH0wBb0gALTgAnTgBfT
    wCjTgALUgAnUgBfUwCjUgALWgAnWgBfWwCjWgALdgAndgBfdwCjdgAPTgAbTgArTgA/TgBjTgB/T
    gCnTwDjTgAPUgAbUgArUgA/UgBjUgB/UgCnUwDjUgAPWgAbWgArWgA/WgBjWgB/WgCnWwDjWgAPd
    gAbdgArdgA/dgBjdgB/dgCndwDjdgALegAnegBfewCjegALfgAnfgBffwCjfgALxgAnxgBfxwCjx
    gAL0gAn0gBf0wCj0gAPegAbegAregA/egBjegB/egCnewDjegAPfgAbfgArfgA/fgBjfgB/fgCnf
    wDjfgAPxgAbxgArxgA/xgBjxgB/xgCnxwDjxgAP0gAb0gAr0gA/0gBj0gB/0gCn0wDj0gAH1wBb1
    gAH2wBb2gAH3wBb3gAH4wBb4gAH6wBb6gAH7wBb7gAH8wBb8gAH9wBb9gAL1gAn1gBf1wCj1gAL2
    gAn2gBf2wCj2gAL3gAn3gBf3wCj3gAL4gAn4gBf4wCj4gAP1gAb1gAr1gA/1gBj1gB/1gCn1wDj1
    gAP2gAb2gAr2gA/2gBj2gB/2gCn2wDj2gAP3gAb3gAr3gA/3gBj3gB/3gCn3wDj3gAP4gAb4gAr4
    gA/4gBj4gB/4gCn4wDj4gAL6gAn6gBf6wCj6gAL7gAn7gBf7wCj7gAL8gAn8gBf8wCj8gAL9gAn9
    gBf9wCj9gAP6gAb6gAr6gA/6gBj6gB/6gCn6wDj6gAP7gAb7gAr7gA/7gBj7gB/7gCn7wDj7gAP8
    gAb8gAr8gA/8gBj8gB/8gCn8wDj8gAP9gAb9gAr9gA/9gBj9gB/9gCn9wDj9wAD+AOMAAOUAAOYA
    AOkAAOoAAOwAAO0AAPEAAPIAAPQAAPUAAPgAAPkAAPsAAPwAgAH+wBb+wAACwAADwAAEwAAFwAAG
    wAAHwAAIwAALwAAMwAAOwAAPwAAQwAARwAASgAL+gAn+gBf+wCj+gAECwBYCgAEDwBYDgAEEwBYE
    gAEFwBYFgAEGwBYGgAEHwBYHgAP+gAb+gAr+gA/+gBj+gB/+gCn+wDj+gAICgAkCgBcCwCgCgAID
    gAkDgBcDwCgDgAMCgAYCgAoCgA8CgBgCgB8CgCkCwDgCgAMDgAYDgAoDgA8DgBgDgB8DgCkDwDgD
    gAIEgAkEgBcEwCgEgAIFgAkFgBcFwCgFgAIGgAkGgBcGwCgGgAIHgAkHgBcHwCgHgAMEgAYEgAoE
    gA8EgBgEgB8EgCkEwDgEgAMFgAYFgAoFgA8FgBgFgB8FgCkFwDgFgAMGgAYGgAoGgA8GgBgGgB8G
    gCkGwDgGgAMHgAYHgAoHgA8HgBgHgB8HgCkHwDgHgAEIwBYIgAELwBYLgAEMwBYMgAEOwBYOgAEP
    wBYPgAEQwBYQgAERwBYRgAESwBYSgAIIgAkIgBcIwCgIgAILgAkLgBcLwCgLgAIMgAkMgBcMwCgM
    gAIOgAkOgBcOwCgOgAMIgAYIgAoIgA8IgBgIgB8IgCkIwDgIgAMLgAYLgAoLgA8LgBgLgB8LgCkL
    wDgLgAMMgAYMgAoMgA8MgBgMgB8MgCkMwDgMgAMOgAYOgAoOgA8OgBgOgB8OgCkOwDgOgAIPgAkP
    gBcPwCgPgAIQgAkQgBcQwCgQgAIRgAkRgBcRwCgRgAISgAkSgBcSwCgSgAMPgAYPgAoPgA8PgBgP
    gB8PgCkPwDgPgAMQgAYQgAoQgA8QgBgQgB8QgCkQwDgQgAMRgAYRgAoRgA8RgBgRgB8RgCkRwDgR
    gAMSgAYSgAoSgA8SgBgSgB8SgCkSwDgSwAATwAAUwAAVwAAXwAAYwAAZwAAawAAbwAAcwAAdwAAe
    wAAfwAB/wADcwAD5AP0AgAETwBYTgAEUwBYUgAEVwBYVgAEXwBYXgAEYwBYYgAEZwBYZgAEawBYa
    gAEbwBYbgAITgAkTgBcTwCgTgAIUgAkUgBcUwCgUgAIVgAkVgBcVwCgVgAIXgAkXgBcXwCgXgAMT
    gAYTgAoTgA8TgBgTgB8TgCkTwDgTgAMUgAYUgAoUgA8UgBgUgB8UgCkUwDgUgAMVgAYVgAoVgA8V
    gBgVgB8VgCkVwDgVgAMXgAYXgAoXgA8XgBgXgB8XgCkXwDgXgAIYgAkYgBcYwCgYgAIZgAkZgBcZ
    wCgZgAIagAkagBcawCgagAIbgAkbgBcbwCgbgAMYgAYYgAoYgA8YgBgYgB8YgCkYwDgYgAMZgAYZ
    gAoZgA8ZgBgZgB8ZgCkZwDgZgAMagAYagAoagA8agBgagB8agCkawDgagAMbgAYbgAobgA8bgBgb
    gB8bgCkbwDgbgAEcwBYcgAEdwBYdgAEewBYegAEfwBYfgAF/wBZ/gAHcwBbcgAH5wBb5AP4AAP8A
    gAIcgAkcgBccwCgcgAIdgAkdgBcdwCgdgAIegAkegBcewCgegAIfgAkfgBcfwCgfgAMcgAYcgAoc
    gA8cgBgcgB8cgCkcwDgcgAMdgAYdgAodgA8dgBgdgB8dgCkdwDgdgAMegAYegAoegA8egBgegB8e
    gCkewDgegAMfgAYfgAofgA8fgBgfgB8fgCkfwDgfgAJ/gAl/gBd/wCh/gALcgAncgBfcwCjcgAL5
    gAn5gBf5wCj5wAAKwAANwAAWAQAAgAN/gAZ/gAp/gA9/gBh/gB9/gCl/wDh/gAPcgAbcgArcgA/c
    gBjcgB/cgCncwDjcgAP5gAb5gAr5gA/5gBj5gB/5gCn5wDj5gAEKwBYKgAENwBYNgAEWwBYWAQAA
    AQAAgAIKgAkKgBcKwCgKgAINgAkNgBcNwCgNgAIWgAkWgBcWwCgWAQAAAQAAAQAAAQAAgAMKgAYK
    gAoKgA8KgBgKgB8KgCkKwDgKgAMNgAYNgAoNgA8NgBgNgB8NgCkNwDgNgAMWgAYWgAoWgA8WgBgW
    gB8WgCkWwDgWAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAA
    AQAAAQAAAQAAAQAAAQAAAQAAAQAAAQAA
    """

    private static let decoded: (table: [[HuffmanDecodeNode]], isValid: Bool) = {
        // Rule: Strip whitespace and newlines before decoding to avoid base64 decode failures.
        let sanitized = encodedTableBase64
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let data = Data(base64Encoded: sanitized) else {
            // Safety: Avoid crashing the extension for decode-table issues.
            return ([], false)
        }

        var nodes: [HuffmanDecodeNode] = []
        let expectedCapacity: Int = data.count / 3
        nodes.reserveCapacity(expectedCapacity)

        var index: Data.Index = data.startIndex
        let endIndex: Data.Index = data.endIndex
        while index + 2 < endIndex {
            let fstate: UInt16 = (UInt16(data[index]) << 8) | UInt16(data[index + 1])
            let sym: UInt8 = data[index + 2]
            nodes.append(HuffmanDecodeNode(fstate: fstate, sym: sym))
            index = data.index(index, offsetBy: 3)
        }

        guard nodes.count % 16 == 0 else {
            // Safety: Avoid crashing the extension for decode-table issues.
            return ([], false)
        }

        var table: [[HuffmanDecodeNode]] = []
        let tableCapacity: Int = nodes.count / 16
        table.reserveCapacity(tableCapacity)

        var offset = 0
        let nodeCount: Int = nodes.count
        while offset < nodeCount {
            let slice: [HuffmanDecodeNode] = Array(nodes[offset ..< offset + 16])
            table.append(slice)
            offset += 16
        }

        return (table, true)
    }()

    public static var table: [[HuffmanDecodeNode]] {
        decoded.table
    }

    public static var isValid: Bool {
        decoded.isValid
    }
}

// Rule: Access via a computed property to keep lazy initialization.
var huffmanDecodeTable: [[HuffmanDecodeNode]] {
    HuffmanDecodeTable.table
}
