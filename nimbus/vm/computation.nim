# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, macros, terminal, math, tables,
  eth_common,
  ../constants, ../errors, ../validation, ../vm_state, ../vm_types,
  ./interpreter/[opcode_values, gas_meter, gas_costs, vm_forks],
  ./code_stream, ./memory, ./message, ./stack

logScope:
  topics = "vm computation"

proc newBaseComputation*(vmState: BaseVMState, blockNumber: UInt256, message: Message): BaseComputation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter.init(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[EthAddress, EthAddress]()
  result.logEntries = @[]
  result.code = newCodeStream(message.code)
  # result.rawOutput = "0x"
  result.gasCosts = blockNumber.toFork.forkToSchedule

proc isOriginComputation*(c: BaseComputation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.isOrigin

template isSuccess*(c: BaseComputation): bool =
  c.error.isNil

template isError*(c: BaseComputation): bool =
  not c.isSuccess

func shouldBurnGas*(c: BaseComputation): bool =
  c.isError and c.error.burnsGas

func shouldEraseReturnData*(c: BaseComputation): bool =
  c.isError and c.error.erasesReturnData

func bytesToHex(x: openarray[byte]): string {.inline.} =
  ## TODO: use seq[byte] for raw data and delete this proc
  foldl(x, a & b.int.toHex(2).toLowerAscii, "0x")

func output*(c: BaseComputation): seq[byte] =
  if c.shouldEraseReturnData:
    @[]
  else:
    c.rawOutput

func `output=`*(c: var BaseComputation, value: openarray[byte]) =
  c.rawOutput = @value

proc outputHex*(c: BaseComputation): string =
  if c.shouldEraseReturnData:
    return "0x"
  c.rawOutput.bytesToHex

proc prepareChildMessage*(
    c: var BaseComputation,
    gas: GasInt,
    to: EthAddress,
    value: UInt256,
    data: seq[byte],
    code: seq[byte],
    options: MessageOptions = newMessageOptions()): Message =

  var childOptions = options
  childOptions.depth = c.msg.depth + 1
  result = newMessage(
    gas,
    c.msg.gasPrice,
    c.msg.origin,
    to,
    value,
    data,
    code,
    childOptions)

proc applyCreateMessage(computation: BaseComputation): BaseComputation =
  # TODO: This needs to be different depending on fork.
  raise newException(NotImplementedError, "Apply create message not implemented")

proc applyMessage(computation: BaseComputation): BaseComputation =
  # TODO: This needs to be different depending on fork.
  raise newException(NotImplementedError, "Apply message not implemented")

proc generateChildComputation*(computation: BaseComputation, childMsg: Message): BaseComputation =
  new result
  if childMsg.isCreate:
    result = newBaseComputation(
      computation.vmState,
      computation.vmState.blockHeader.blockNumber,
      childMsg).applyCreateMessage()
  else:
    result = newBaseComputation(
      computation.vmState,
      computation.vmState.blockHeader.blockNumber,
      childMsg).applyMessage()

proc addChildComputation(computation: BaseComputation, child: BaseComputation) =
  if child.isError:
    if child.msg.isCreate:
      computation.returnData = child.output
    elif child.shouldBurnGas:
      computation.returnData = @[]
    else:
      computation.returnData = child.output
  else:
    if child.msg.isCreate:
      computation.returnData = @[]
    else:
      computation.returnData = child.output
  computation.children.add(child)

proc applyChildComputation*(computation: BaseComputation, childMsg: Message): BaseComputation =
  ## Apply the vm message childMsg as a child computation.
  result = computation.generateChildComputation(childMsg)
  computation.addChildComputation(result)

proc registerAccountForDeletion*(c: var BaseComputation, beneficiary: EthAddress) =
  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary

proc addLogEntry*(c: var BaseComputation, account: EthAddress, topics: seq[UInt256], data: seq[byte]) =
  c.logEntries.add((account, topics, data))

# many methods are basically TODO, but they still return valid values
# in order to test some existing code
func getAccountsForDeletion*(c: BaseComputation): seq[EthAddress] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]
    for account in c.accountsToDelete.keys:
        result.add(account)

proc getLogEntries*(c: BaseComputation): seq[(string, seq[UInt256], string)] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]

proc getGasRefund*(c: BaseComputation): GasInt =
  if c.isError:
    result = 0
  else:
    result = c.gasMeter.gasRefunded + c.children.mapIt(it.getGasRefund()).foldl(a + b, 0'i64)

proc getGasUsed*(c: BaseComputation): GasInt =
  if c.shouldBurnGas:
    result = c.msg.gas
  else:
    result = max(0, c.msg.gas - c.gasMeter.gasRemaining)

proc getGasRemaining*(c: BaseComputation): GasInt =
  if c.shouldBurnGas:
    result = 0
  else:
    result = c.gasMeter.gasRemaining
