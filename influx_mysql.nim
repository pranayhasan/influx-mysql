{.boundChecks: on.}

import macros
import future
import strtabs
import strutils
import asyncdispatch
import asyncnet
import asynchttpserver
from net import BufferSize, TimeoutError
import lists
import hashes as hashes
import tables
import json
import base64
import cgi
import times
import os
import sets

import qt5_qtsql

import reflists
import microasynchttpserver
import qsqldatabase
import qvariant
import qttimespec
import qdatetime
import qsqlrecord
import influxql_to_sql
import influx_line_protocol_to_sql

type 
    DBQueryException = object of IOError
    URLParameterError = object of ValueError
    URLParameterNotFoundError = object of URLParameterError
    URLParameterInvalidError = object of URLParameterError

    JSONEntryValues = tuple
        order: OrderedTableRef[ref string, bool] not nil
        entries: SinglyLinkedRefList[Table[ref string, JSONField]] not nil

    SeriesAndData = tuple
        series: string
        data: JSONEntryValues

    # InfluxDB only supports four data types, which makes this easy
    # We add a fifth one so that we can properly support unsigned integers
    JSONFieldKind {.pure.} = enum
        Null,
        Integer,
        UInteger,
        Float,
        Boolean,
        String

    JSONField = object
        case kind: JSONFieldKind
        of JSONFieldKind.Null: discard
        of JSONFieldKind.Integer: intVal: int64
        of JSONFieldKind.UInteger: uintVal: uint64
        of JSONFieldKind.Float: floatVal: float64
        of JSONFieldKind.Boolean: booleanVal: bool
        of JSONFieldKind.String: stringVal: string

    QVariantType {.pure.} = enum
        Bool = 1
        Int = 2
        UInt = 3
        LongLong = 4
        ULongLong = 5
        Double = 6
        Char = 7
        String = 10
        Date = 14
        Time = 15
        DateTime = 16
        Long = 129
        Short = 130
        Char2 = 131
        ULong = 132
        UShort = 133
        UChar = 134
        Float = 135

    EpochFormat {.pure.} = enum
        RFC3339
        Hour
        Minute
        Second
        Millisecond
        Microsecond
        Nanosecond

const QUERY_HTTP_METHODS = "GET"
const WRITE_HTTP_METHODS = "POST"
const PING_HTTP_METHODS = "GET, HEAD"

const cacheControlZeroAge: string = "0"

when getEnv("cachecontrolmaxage") != "":
    const cachecontrolmaxage: string = getEnv("cachecontrolmaxage")
else:
    const cachecontrolmaxage: string = "0"

const cacheControlDontCacheHeader = "private, max-age=" & cacheControlZeroAge & ", s-maxage=" & cacheControlZeroAge & ", no-cache"
const cacheControlDoCacheHeader = "public, max-age=" & cachecontrolmaxage & ", s-maxage=" & cachecontrolmaxage

# sqlbuffersize sets the initial size of the SQL INSERT query buffer for POST /write commands.
# The default size is MySQL's default max_allowed_packet value. Setting this to a higher size
# will improve memory usage for INSERTs larger than the size, at the expense of overallocating
# memory for INSERTs smaller than the size.
when getEnv("sqlbuffersize") == "":
    const SQL_BUFFER_SIZE = 2097152
else:
    const SQL_BUFFER_SIZE = getEnv("sqlbuffersize").parseInt

var corsAllowOrigin: cstring = nil

template JSON_CONTENT_TYPE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "application/json", "Cache-Control", cacheControlDoCacheHeader, modeCaseSensitive)

template JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "application/json", "Cache-Control", cacheControlDontCacheHeader, modeCaseSensitive)

template TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "text/plain", "Cache-Control", cacheControlDontCacheHeader, modeCaseSensitive)

template TEXT_CONTENT_TYPE_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "text/plain", "Cache-Control", cacheControlDoCacheHeader, modeCaseSensitive)

template PING_RESPONSE_HEADERS(): StringTableRef =
    newStringTable("Content-Type", "text/plain", "Cache-Control", cacheControlDontCacheHeader, "Date", date, "X-Influxdb-Version", "0.9.3-compatible-influxmysql", modeCaseSensitive)

var dbHostname: cstring = nil
var dbPort: cint = 0

template hash(x: ref string): Hash =
    hashes.hash(cast[pointer](x))

macro useDB(dbName: string, dbUsername: string, dbPassword: string, body: stmt): stmt {.immediate.} =
    # Create the try block that closes the database.
    var safeBodyClose = newNimNode(nnkTryStmt)
    safeBodyClose.add(body)

    ## Create the finally clause
    var safeBodyCloseFinally = newNimNode(nnkFinally)
    safeBodyCloseFinally.add(parseStmt("database.close"))
    
    ## Add the finally clause to the try block.
    safeBodyClose.add(safeBodyCloseFinally)

    # Create the try block that removes the database.
    var safeBodyRemove = newNimNode(nnkTryStmt)
    safeBodyRemove.add(
        newBlockStmt(
            newStmtList(
                newVarStmt(newIdentNode(!"database"), newCall(!"newQSqlDatabase", newStrLitNode("QMYSQL"), newIdentNode(!"qSqlDatabaseName"))),
                newCall(!"setHostName", newIdentNode(!"database"), newIdentNode(!"dbHostName")),
                newCall(!"setDatabaseName", newIdentNode(!"database"), dbName),
                newCall(!"setPort", newIdentNode(!"database"), newIdentNode(!"dbPort")),
                newCall(!"open", newIdentNode(!"database"), dbUsername, dbPassword),
                safeBodyClose
            )
        )
    )

    ## Create the finally clause.
    var safeBodyRemoveFinally = newNimNode(nnkFinally)
    safeBodyRemoveFinally.add(parseStmt("qSqlDatabaseRemoveDatabase(qSqlDatabaseName)"))

    ## Add the finally clause to the try block.
    safeBodyRemove.add(safeBodyRemoveFinally)

    # Put it all together.
    result = newBlockStmt(
                newStmtList(
                    parseStmt("""

var qSqlDatabaseStackId: uint8
var qSqlDatabaseName = "influx_mysql" & $cast[uint64](addr(qSqlDatabaseStackId))
                    """), 
                    safeBodyRemove
                )
            )

proc strdup(s: var string): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

proc strdup(s: var cstring): string =
    result = newString(s.len)
    copyMem(addr(result[0]), addr(s[0]), result.len)

template useQuery(sql: cstring, query: var QSqlQueryObj) {.dirty.} =
    try:
        query.prepare(sql)
        query.exec
    except QSqlException:
        var exceptionMsg = cast[string](getCurrentExceptionMsg())
        var newExceptionMsg = exceptionMsg.strdup

        raise newException(DBQueryException, newExceptionMsg)

template useQuery(sql: cstring, database: var QSqlDatabaseObj) {.dirty.} =
    var query = database.qSqlQuery()
    sql.useQuery(query)

proc runDBQueryWithTransaction(sql: cstring, dbName: string, dbUsername: string, dbPassword: string) =
    useDB(dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='UTC'".useQuery(database)

        database.beginTransaction
        sql.useQuery(database)
        database.commitTransaction

        # Workaround for weird compiler corner case
        database.close

proc getParams(request: Request): StringTableRef =
    result = newStringTable(modeCaseSensitive)

    for part in request.url.query.split('&'):
        let keyAndValue = part.split('=')

        if (keyAndValue.len == 2):
            result[keyAndValue[0]] = keyAndValue[1].decodeUrl

proc toRFC3339JSONField(dateTime: QDateTimeObj): JSONField =
    var timeStringConst = dateTime.toQStringObj("yyyy-MM-ddThh:mm:ss.zzz000000Z").toUtf8.constData.umc

    result.kind = JSONFieldKind.String
    result.stringVal = timeStringConst.strdup

proc toJSONField(dateTime: QDateTimeObj, epoch: EpochFormat): JSONField =
    case epoch:
    of EpochFormat.RFC3339:
        result = dateTime.toRFC3339JSONField
    of EpochFormat.Hour:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = uint64(dateTime.toMSecsSinceEpoch) div 3600000
    of EpochFormat.Minute:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = uint64(dateTime.toMSecsSinceEpoch) div 60000
    of EpochFormat.Second:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = uint64(dateTime.toMSecsSinceEpoch) div 1000
    of EpochFormat.Millisecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = uint64(dateTime.toMSecsSinceEpoch)
    of EpochFormat.Microsecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = uint64(dateTime.toMSecsSinceEpoch) * 1000
    of EpochFormat.Nanosecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = uint64(dateTime.toMSecsSinceEpoch) * 1000000

proc toJSONField(record: QSqlRecordObj, i: cint, epoch: EpochFormat): JSONField =
    if not record.isNull(i):
        var valueVariant = record.value(i)

        case QVariantType(valueVariant.userType):
        of QVariantType.Date, QVariantType.Time, QVariantType.DateTime:
            var dateTime = valueVariant.toQDateTimeObj
            dateTime.setTimeSpec(QtUtc)

            result = dateTime.toJSONField(epoch)

        of QVariantType.Bool:

            result.kind = JSONFieldKind.Boolean
            result.booleanVal = valueVariant
        
        of QVariantType.Int, QVariantType.LongLong, QVariantType.Char, QVariantType.Long,
            QVariantType.Short, QVariantType.Char2: 

            result.kind = JSONFieldKind.Integer
            result.intVal = valueVariant

        of QVariantType.UInt, QVariantType.ULongLong, QVariantType.ULong,
            QVariantType.UShort, QVariantType.UChar:

            result.kind = JSONFieldKind.UInteger
            result.uintVal = valueVariant

        of QVariantType.Double, QVariantType.Float:

            result.kind = JSONFieldKind.Float
            result.floatVal = valueVariant

        of QVariantType.String:

            var valueStringConst = valueVariant.toQStringObj.toUtf8.constData.umc

            result.kind = JSONFieldKind.String
            result.stringVal = valueStringConst.strdup

        else:

            raise newException(ValueError, "Cannot unpack QVariantObj of type \"" & $valueVariant.userType & "\"!")
    else:
        result.kind = JSONFieldKind.Null

proc addNulls(entries: SinglyLinkedRefList[Table[ref string, JSONField]] not nil, order: OrderedTableRef[ref string, bool] not nil,
                lastTime: uint64, newTime: uint64, period: uint64, epoch: EpochFormat, internedStrings: var Table[string, ref string]) =

    var lastTime = lastTime
    let timeInterned = internedStrings["time"]

    if ((newTime - lastTime) div period) > uint64(1):
        while true:
            lastTime += period

            if lastTime >= newTime:
                break

            var entryValues = newTable[ref string, JSONField]()
            for fieldName in order.keys:
                if fieldName != timeInterned:
                    entryValues[fieldName] = JSONField(kind: JSONFieldKind.Null)
                else:
                    entryValues[timeInterned] = newQDateTimeObj(qint64(lastTime), QtUtc).toJSONField(epoch)

            entries.append(entryValues)

proc runDBQueryAndUnpack(sql: cstring, series: string, period: uint64, fillNull: bool, dizcard: HashSet[string], epoch: EpochFormat, result: var DoublyLinkedList[SeriesAndData], internedStrings: var Table[string, ref string],
                         dbName: string, dbUsername: string, dbPassword: string)  =
    useDB(dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='UTC'".useQuery(database)

        sql.useQuery(database)

        var entries = newSinglyLinkedRefList[Table[ref string, JSONField]]()
        var seriesAndData: SeriesAndData = (series: series, data: (order: cast[OrderedTableRef[ref string, bool] not nil](newOrderedTable[ref string, bool]()), 
                                entries: entries))
        result.append(seriesAndData)

        var order = seriesAndData.data.order

        var lastTime = uint64(0)
        var first = true

        while query.next() == true:
            var record = query.record
            let count = record.count - 1

            var entryValues = newTable[ref string, JSONField]()

            if fillNull:
                # For strict InfluxDB compatibility:
                #
                # InfluxDB will automatically return NULLs if there is no data for that GROUP BY timeframe block.
                # SQL databases do not do this, they return nothing if there is no data. So we need to add these
                # NULLs.
                var newTime = uint64(record.value("time").toMSecsSinceEpoch)

                if (period > uint64(0)) and not first:
                    entries.addNulls(order, lastTime, newTime, period, epoch, internedStrings)
                else:
                    first = false

                lastTime = newTime

            for i in countUp(0, count):
                var fieldNameConst = record.fieldName(i).toUtf8.constData.umc
                var fieldName: string = fieldNameConst.strdup

                if (not dizcard.contains(fieldName)):
                    # For strict InfluxDB compatibilty:
                    #
                    # We only return the name of the functions as the field, and not the name and the arguments.
                    #
                    # We also change "AVG" to "mean" since we change "mean" to "AVG" in the InfluxQL to SQL conversion.
                    if fieldName[fieldName.len-1] == ')':
                        fieldName = fieldName.getToken('(', 0)

                        if fieldName == "AVG":
                            fieldName = "mean"

                    var value = record.toJSONField(i, epoch)

                    var fieldNameInterned = internedStrings.getOrDefault(fieldName)
                    if fieldnameInterned == nil:
                        new(fieldNameInterned)
                        fieldNameInterned[] = fieldName

                        internedStrings[fieldName] = fieldNameInterned

                    discard order.hasKeyOrPut(fieldNameInterned, true)
                    entryValues[fieldNameInterned] = value

            entries.append(entryValues)

converter toJsonNode(field: JSONField): JsonNode =
    case field.kind:
    of JSONFieldKind.Null: result = newJNull()
    of JSONFieldKind.Integer: result = newJInt(BiggestInt(field.intVal))
    of JSONFieldKind.UInteger: result = newJInt(BiggestInt(field.uintVal))
    of JSONFieldKind.Float: result = newJFloat(field.floatVal)
    of JSONFieldKind.Boolean: result = newJBool(field.booleanVal)
    of JSONFieldKind.String: result = newJString(field.stringVal)

proc toJsonNode(kv: SeriesAndData): JsonNode =
    result = newJObject()
    var seriesArray = newJArray()
    var seriesObject = newJObject()

    seriesObject.add("name", newJString(kv.series))

    var columns = newJArray()

    for column in kv.data.order.keys:
        columns.add(newJString(column[]))

    seriesObject.add("columns", columns)

    var valuesArray = newJArray()

    for entry in kv.data.entries.items:
        var entryArray = newJArray()

        for column in kv.data.order.keys:
            entryArray.add(entry[column])

        valuesArray.add(entryArray)

    seriesObject.add("values", valuesArray)

    seriesArray.add(seriesObject)
    result.add("series", seriesArray)

proc toQueryResponse(ev: DoublyLinkedList[SeriesAndData]): string =
    var json = newJObject()
    var results = newJArray()

    for keyAndValue in ev.items:
        results.add(keyAndValue.toJsonNode)

    json.add("results", results)
    result = $json

proc withCorsIfNeeded(headers: StringTableRef, allowMethods: string, accessControlMaxAge: string): StringTableRef =
    if corsAllowOrigin != nil:
        if allowMethods != nil:
            headers["Access-Control-Allow-Methods"] = allowMethods

        if accessControlMaxAge != nil:
            headers["Access-Control-Max-Age"] = accessControlMaxAge

        headers["Access-Control-Allow-Origin"] = $corsAllowOrigin
        headers["Access-Control-Allow-Headers"] = "Accept, Origin, Authorization"
        headers["Access-Control-Allow-Credentials"] = "true"

    result = headers

proc withCorsIfNeeded(headers: StringTableRef, allowMethods: string): StringTableRef =
    if headers["Cache-Control"] == cacheControlDoCacheHeader:
        result = headers.withCorsIfNeeded(allowMethods, cachecontrolmaxage)
    elif headers["Cache-Control"] == cacheControlDontCacheHeader:
        result = headers.withCorsIfNeeded(allowMethods, cacheControlZeroAge)
    else:
        result = headers.withCorsIfNeeded(allowMethods, nil)

proc getOrHeadPing(request: Request): Future[void] =
    let date = getTime().getGMTime.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
    result = request.respond(Http204, "", PING_RESPONSE_HEADERS.withCorsIfNeeded(PING_HTTP_METHODS))

proc basicAuthToUrlParam(request: var Request) =
    if not request.headers.hasKey("Authorization"):
        return

    let parts = request.headers["Authorization"].split(' ')

    if (parts.len != 2) or (parts[0] != "Basic"):
        return

    let userNameAndPassword = base64.decode(parts[1]).split(':')

    if (userNameAndPassword.len != 2):
        return

    request.url.query.add("&u=")
    request.url.query.add(userNameAndPassword[0].encodeUrl)

    request.url.query.add("&p=")
    request.url.query.add(userNameAndPassword[1].encodeUrl)

proc getQuery(request: Request): Future[void] =
    var internedStrings = initTable[string, ref string]()

    var timeInterned: ref string
    new(timeInterned)
    timeInterned[] = "time"

    internedStrings["time"] = timeInterned

    var entries = initDoublyLinkedList[tuple[series: string, data: JSONEntryValues]]()

    try:
        GC_disable()

        let params = getParams(request)

        let urlQuery = params["q"]
        let specifiedEpochFormat = params.getOrDefault("epoch")

        var epoch = EpochFormat.RFC3339

        if specifiedEpochFormat != "":
            case specifiedEpochFormat:
            of "h": epoch = EpochFormat.Hour
            of "m": epoch = EpochFormat.Minute
            of "s": epoch = EpochFormat.Second
            of "ms": epoch = EpochFormat.Millisecond
            of "u": epoch = EpochFormat.Microsecond
            of "ns": epoch = EpochFormat.Nanosecond
            else:
                raise newException(URLParameterInvalidError, "Invalid epoch parameter specified!")

        if urlQuery == nil:
            raise newException(URLParameterNotFoundError, "No \"q\" query parameter specified!")

        var dbName = ""
        var dbUsername = ""
        var dbPassword = ""

        if params.hasKey("db"):
            dbName = params["db"]

        if params.hasKey("u"):
            dbUsername = params["u"]

        if params.hasKey("p"):
            dbPassword = params["p"]

        var cache = true

        for line in urlQuery.splitLines:
            var series: string
            var period = uint64(0)
            var fillNull = false
            var dizcard = initSet[string]()

            let sql = line.influxQlToSql(series, period, fillNull, cache, dizcard)
            
            when defined(logrequests):
                stdout.write("/query: ")
                stdout.write(line)
                stdout.write(" --> ")
                stdout.writeLine(sql)

            try:
                sql.runDBQueryAndUnpack(series, period, fillNull, dizcard, epoch, entries, internedStrings, dbName, dbUsername, dbPassword)
            except DBQueryException:
                stdout.write("/query: ")
                stdout.write(line)
                stdout.write(" --> ")
                stdout.writeLine(sql)
                raise getCurrentException()

        if cache != false:
            result = request.respond(Http200, entries.toQueryResponse, JSON_CONTENT_TYPE_RESPONSE_HEADERS.withCorsIfNeeded(QUERY_HTTP_METHODS))
        else:
            result = request.respond(Http200, entries.toQueryResponse, JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(QUERY_HTTP_METHODS))
    finally:
        try:
            # SQLEntryValues.entries is a manually allocated object, so we
            # need to free it.
            for entry in entries.items:
                entry.data.entries.removeAll
        finally:
            GC_enable()

import posix

when defined(linux):
    import linux
else:
    const MSG_DONTWAIT = 0

type
    ReadLinesFutureContext = ref tuple
        contentLength: int
        read: int
        noReadsCount: int
        readNow: string
        line: string
        lines: string
        internedStrings: Table[string, ref string]
        entries: Table[ref string, SQLEntryValues]
        request: Request
        retFuture: Future[ReadLinesFutureContext]
        routerResult: Future[void]

proc destroyReadLinesFutureContext(context: ReadLinesFutureContext) =
    try:
        GC_disable()

        # SQLEntryValues.entries is a manually allocated object, so we
        # need to free it.
        for entry in context.entries.values:
            entry.entries.removeAll

        # Probably not needed, but better safe than sorry
        if not context.retFuture.finished:
            asyncCheck context.retFuture
            context.retFuture.complete(nil)

        # Probably not needed, but better safe than sorry
        if not context.routerResult.finished:
            context.routerResult.complete
    finally:
        GC_enable()

proc respondError(request: Request, e: ref Exception, eMsg: string) =
    stderr.write(e.getStackTrace())
    stderr.write("Error: unhandled exception: ")
    stderr.writeLine(eMsg)

    var errorResponseHeaders = JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS

    if request.reqMethod != nil:
        errorResponseHeaders = errorResponseHeaders.withCorsIfNeeded(request.reqMethod.toUpper)
    else:
        errorResponseHeaders = errorResponseHeaders.withCorsIfNeeded(nil)

    asyncCheck request.respond(Http400, $( %*{ "error": eMsg } ), errorResponseHeaders)

proc postReadLines(context: ReadLinesFutureContext) =
    try:
        GC_disable()

        var chunkLen = context.contentLength - context.read
        while true:
            if chunkLen > 0:
                if chunkLen > BufferSize:
                    chunkLen = BufferSize

                # Do a non-blocking read of data from the socket
                context.request.client.rawRecv(context.readNow, chunkLen, MSG_DONTWAIT)
                if context.readNow.len < 1:
                    # We didn't get data, check if client disconnected
                    if (errno != EAGAIN) and (errno != EWOULDBLOCK):
                        raise newException(IOError, "Client socket disconnected!")
                    else:
                        # Client didn't disconnect, it's just slow.
                        # Start penalizing the client by responding to it slower.
                        # This prevents slowing down other async connections because
                        # of one slow client.
                        context.noReadsCount += 1

                        if context.noReadsCount > 40:
                            # After 40 reads, we've waited a total of more than 15 seconds.
                            # Timeout, probably gave us the wrong Content-Length.
                            raise newException(TimeoutError, "Client is too slow in sending POST body! (Is Content-Length correct?)")

                        # Client gets one freebie
                        if context.noReadsCount > 1:
                            # For every read with no data after the freebie, sleep for
                            # an additional 20 milliseconds
                            let sleepFuture = sleepAsync((context.noReadsCount - 1) * 20)

                            sleepFuture.callback = (proc(future: Future[void]) =
                                context.postReadLines
                            )
                            return

                        continue
                else:
                    # We got data, reset the penalty
                    context.noReadsCount = 0

                context.read += context.readNow.len
                context.lines.add(context.readNow)

            var lineStart = 0
            while lineStart < context.lines.len:
                let lineEnd = context.lines.find("\n", lineStart) - "\n".len

                if lineEnd < 0 or lineEnd >= context.lines.len:
                    break

                let lineNewSize = lineEnd - lineStart + 1
                context.line.setLen(lineNewSize)
                copyMem(addr(context.line[0]), addr(context.lines[lineStart]), lineNewSize)

                if context.line.len > 0:
                    when defined(logrequests):
                        stdout.write("/write: ")
                        stdout.writeLine(context.line)

                    context.line.lineProtocolToSQLEntryValues(context.entries, context.internedStrings)

                lineStart = lineEnd + "\n".len + 1

            if lineStart < context.lines.len:
                let linesNewSize = context.lines.len - lineStart
                
                moveMem(addr(context.lines[0]), addr(context.lines[lineStart]), linesNewSize)
                context.lines.setLen(linesNewSize)
            else:
                context.lines.setLen(0)

            chunkLen = context.contentLength - context.read

            if chunkLen <= 0:
                break

        context.routerResult.complete
        context.retFuture.complete(context)
    except IOError, ValueError, TimeoutError:
        context.routerResult.complete

        context.request.respondError(getCurrentException(), getCurrentExceptionMsg())
        context.destroyReadLinesFutureContext
    finally:
        GC_enable()

proc postReadLines(request: Request, routerResult: Future[void]): Future[ReadLinesFutureContext] =
    var contentLength = 0
    result = newFuture[ReadLinesFutureContext]("postReadLines")

    if request.headers.hasKey("Content-Length"):
        contentLength = request.headers["Content-Length"].parseInt

    if contentLength == 0:
        result.fail(newException(IOError, "Content-Length required, but not provided!"))
        #result = request.respond(Http400, "Content-Length required, but not provided!", TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(WRITE_HTTP_METHODS))
        return

    var timeInterned: ref string
    new(timeInterned)
    timeInterned[] = "time"

    var internedStrings = initTable[string, ref string]()
    internedStrings["time"] = timeInterned

    var context: ReadLinesFutureContext
    new(context, destroyReadLinesFutureContext)
    context[] = (contentLength: contentLength, read: 0, noReadsCount: 0, readNow: newString(BufferSize), line: "", lines: request.client.recvWholeBuffer,
        internedStrings: internedStrings, entries: initTable[ref string, SQLEntryValues](), request: request, retFuture: result, routerResult: routerResult)

    context.read = context.lines.len

    context.postReadLines

proc mget[T](future: Future[T]): var T = asyncdispatch.mget(cast[FutureVar[T]](future))

proc postWriteProcess(ioResult: Future[ReadLinesFutureContext]) =
    try:
        GC_disable()

        let context = ioResult.read
        var sql = newStringOfCap(SQL_BUFFER_SIZE)

        let params = getParams(context.request)

        var dbName = ""
        var dbUsername = ""
        var dbPassword = ""

        if params.hasKey("db"):
            dbName = params["db"]

        if params.hasKey("u"):
            dbUsername = params["u"]

        if params.hasKey("p"):
            dbPassword = params["p"]

        for pair in context.entries.pairs:
            pair.sqlEntryValuesToSQL(sql)

            when defined(logrequests):
                stdout.write("/write: ")
                stdout.writeLine(sql)

            sql.runDBQueryWithTransaction(dbName, dbUsername, dbPassword)
            sql.setLen(0)

        asyncCheck context.request.respond(Http204, "", TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(WRITE_HTTP_METHODS))

        context.destroyReadLinesFutureContext
    except IOError, ValueError, TimeoutError:
        let context = ioResult.mget

        context.request.respondError(getCurrentException(), getCurrentExceptionMsg())
        context.destroyReadLinesFutureContext
    finally:
            GC_enable()

template postWrite(request: Request, routerResult: Future[void]) =
    let ioResult = request.postReadLines(routerResult)
    ioResult.callback = postWriteProcess

template optionsCors(request: Request, allowMethods: string): Future[void] =
    request.respond(Http200, "", TEXT_CONTENT_TYPE_RESPONSE_HEADERS.withCorsIfNeeded(allowMethods))

proc routerHandleError(request: Request, processingResult: Future[void]) =
    try:
        processingResult.read
    except IOError, ValueError, TimeoutError:
        request.respondError(getCurrentException(), getCurrentExceptionMsg())

proc router(request: Request): Future[void] =
    var request = request

    result = newFuture[void]("router")

    try:
        request.basicAuthToUrlParam

        when defined(logrequests):
            stdout.write(request.url.path)
            stdout.write('?')
            stdout.writeLine(request.url.query)

        if (request.reqMethod == "get") and (request.url.path == "/query"):
            result.complete
            request.getQuery.callback = (x: Future[void]) => routerHandleError(request, x)
            return
        elif (request.reqMethod == "post") and (request.url.path == "/write"):
            request.postWrite(result)
            return
        elif ((request.reqMethod == "get") or (request.reqMethod == "head")) and (request.url.path == "/ping"):
            result.complete
            request.getOrHeadPing.callback = (x: Future[void]) => routerHandleError(request, x)
            return
        elif (request.reqMethod == "options") and (corsAllowOrigin != nil):
            result.complete

            case request.url.path:
            of "/query":
                request.optionsCors(QUERY_HTTP_METHODS).callback = (x: Future[void]) => routerHandleError(request, x)
                return
            of "/write":
                request.optionsCors(WRITE_HTTP_METHODS).callback = (x: Future[void]) => routerHandleError(request, x)
                return
            of "/ping":
                request.optionsCors(PING_HTTP_METHODS).callback = (x: Future[void]) => routerHandleError(request, x)
                return
            else:
                discard

        if not result.finished:
            result.complete

        # Fall through on purpose, we didn't have a matching route.
        let responseMessage = "Route not found for [reqMethod=" & request.reqMethod & ", url=" & request.url.path & "]"
        stdout.writeLine(responseMessage)

        request.respond(Http400, responseMessage, TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(request.reqMethod.toUpper)).callback = (x: Future[void]) => routerHandleError(request, x)
    except IOError, ValueError, TimeoutError:
        if not result.finished:
            result.complete

        request.respondError(getCurrentException(), getCurrentExceptionMsg())

proc quitUsage() =
    stderr.writeLine("Usage: influx_mysql <mysql address:mysql port> <influxdb address:influxdb port> [cors allowed origin]")
    quit(QuitFailure)

block:
    var dbHostnameString = "localhost"
    dbPort = 3306

    var httpServerHostname = ""
    var httpServerPort = 8086

    let params = paramCount()

    if (params < 2) or (params > 3):
        if (params < 2):
            stderr.writeLine("Error: Not enough arguments specified!")
        else:
            stderr.writeLine("Error: Too many arguments specified!")

        quitUsage()

    let dbConnectionInfo = paramStr(1).split(':')
    let httpServerInfo = paramStr(2).split(':')

    case dbConnectionInfo.len:
    of 0:
        discard
    of 1:
        dbHostnameString = dbConnectionInfo[0]
    of 2:
        dbHostnameString = dbConnectionInfo[0]

        try:
            dbPort = cint(dbConnectionInfo[1].parseInt)
        except ValueError:
            stderr.writeLine("Error: Invalid mysql port specified!")
            quitUsage()
    else:
        stderr.writeLine("Error: Invalid mysql address, mysql port combination specified!")
        quitUsage()

    case httpServerInfo.len:
    of 0:
        discard
    of 1:
        httpServerHostname = httpServerInfo[0]
    of 2:
        httpServerHostname = httpServerInfo[0]

        try:
            httpServerPort = httpServerInfo[1].parseInt
        except ValueError:
            stderr.writeLine("Error: Invalid influxdb port specified!")
            quitUsage()
    else:
        stderr.writeLine("Error: Invalid influxdb address, influxdb port combination specified!")
        quitUsage()

    dbHostname = cast[cstring](allocShared0(dbHostnameString.len + 1))
    copyMem(addr(dbHostname[0]), addr(dbHostnameString[0]), dbHostnameString.len)

    if params == 3:
        var corsAllowOriginString = paramStr(3)

        corsAllowOrigin = cast[cstring](allocShared0(corsAllowOriginString.len + 1))
        copyMem(addr(corsAllowOrigin[0]), addr(corsAllowOriginString[0]), corsAllowOriginString.len)

    defer:
        deallocShared(dbHostname)

        if (corsAllowOrigin != nil):
            deallocShared(corsAllowOrigin)

    try:
        waitFor newMicroAsyncHttpServer().serve(Port(httpServerPort), router, httpServerHostname)
    except Exception:
        let e = getCurrentException()
        stderr.write(e.getStackTrace())
        stderr.write("Error: unhandled exception: ")
        stderr.writeLine(getCurrentExceptionMsg())

        quit(QuitFailure)
