import { expect } from 'chai';
import * as sinon from 'sinon';
import { Appearance } from '../src/appearance'
import * as Promise from 'bluebird';
import { Scenario } from '../src/scenario';
import { ResultMessage, MessageType, InvocationMessage, ErrorMessage } from '../src/messages';

describe('Appearance', () => {

    describe('with normal actor returns plain value', () => {
        const actor = {
            hello: function (name) {
                return 'world' + name
            }
        }
        var appearance: Appearance, mock;

        beforeEach(() => {
            appearance = new Appearance(actor)
            mock = sinon.mock(Scenario)
        })

        afterEach(() => {
            mock.restore();
        })

        it('sends back result message', (done) => {
            var invMsg: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'hello',
                params: ['!!!'],
                reqid: 1
            }
            var resMsg: ResultMessage = {
                type: MessageType.result,
                from: null,
                to: 'node1',
                result: 'world!!!',
                reqid: 1
            }
            let e = mock.expects('sendMessage').once().withArgs(resMsg);

            appearance.handleInvocation(invMsg);
            setTimeout(function () {
                e.verify();
                done();
            }, 200);
        });

        it('sends back result message one by one', (done) => {
            var invMsg1: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'hello',
                params: ['msg1'],
                reqid: 1
            }
            var invMsg2: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'hello',
                params: ['msg2'],
                reqid: 2
            }
            var resMsg1: ResultMessage = {
                type: MessageType.result,
                from: null,
                to: 'node1',
                result: 'worldmsg1',
                reqid: 1
            }
            var resMsg2: ResultMessage = {
                type: MessageType.result,
                from: null,
                to: 'node1',
                result: 'worldmsg2',
                reqid: 2
            }
            let e = mock.expects('sendMessage').twice();
            appearance.handleInvocation(invMsg1);
            appearance.handleInvocation(invMsg2);
            setTimeout(function () {
                e.verify();
                done();
            }, 200);
        });
    });
    describe('with actor missing requested method', () => {
        const actor = {
        }
        var appearance: Appearance, mock;

        beforeEach(() => {
            appearance = new Appearance(actor)
            mock = sinon.mock(Scenario)
        })

        afterEach(() => {
            mock.restore();
        })
        it('returns error', (done) => {
            var invMsg: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'hello',
                params: ['!!!'],
                reqid: 1
            }
            var resMsg: ErrorMessage = {
                type: MessageType.error,
                from: null,
                to: 'node1',
                name: 'NoMethodError',
                message: 'no such method hello',
                reqid: 1
            }
            let e = mock.expects('sendMessage').once().withArgs(resMsg);

            appearance.handleInvocation(invMsg);
            setTimeout(function () {
                e.verify();
                done();
            }, 200);
        });
    });
    describe('when actor method throws error', () => {
        const actor = {
            hello: function () {
                return this.test();
            }
        }
        var appearance: Appearance, mock;

        beforeEach(() => {
            appearance = new Appearance(actor)
            mock = sinon.mock(Scenario)
        })

        afterEach(() => {
            mock.restore();
        })
        it('returns error', (done) => {
            var invMsg: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'hello',
                params: ['!!!'],
                reqid: 1
            }
            var resMsg: ErrorMessage = {
                type: MessageType.error,
                from: null,
                to: 'node1',
                name: 'TypeError',
                message: 'this.test is not a function',
                reqid: 1
            }
            let e = mock.expects('sendMessage').once().withArgs(sinon.match(resMsg));

            appearance.handleInvocation(invMsg);
            setTimeout(function () {
                e.verify();
                done();
            }, 200);
        });
    })

    describe('when actor method returns promise', () => {
        const actor = {
            hello: function (name) {
                return Promise.resolve("world"+name);
            },
            willReject: function(name){
                return Promise.reject({
                    name: 'TestError',
                    message: 'only a test'
                })
            }
        }
        var appearance: Appearance, mock;

        beforeEach(() => {
            appearance = new Appearance(actor)
            mock = sinon.mock(Scenario)
        })

        afterEach(() => {
            mock.restore();
        })
        it('returns error', (done) => {
            var invMsg: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'willReject',
                params: ['!!!'],
                reqid: 1
            }
            var resMsg: ErrorMessage = {
                type: MessageType.error,
                from: null,
                to: 'node1',
                name: 'TestError',
                message: 'only a test',
                reqid: 1
            }
            let e = mock.expects('sendMessage').once().withArgs(sinon.match(resMsg));

            appearance.handleInvocation(invMsg);
            setTimeout(function () {
                e.verify();
                done();
            }, 200);
        });

        it('sends back result message', (done) => {
            var invMsg: InvocationMessage = {
                type: MessageType.invocation,
                from: 'node1',
                to: 'test',
                method: 'hello',
                params: ['!!!'],
                reqid: 1
            }
            var resMsg: ResultMessage = {
                type: MessageType.result,
                from: null,
                to: 'node1',
                result: 'world!!!',
                reqid: 1
            }
            let e = mock.expects('sendMessage').once().withArgs(resMsg);

            appearance.handleInvocation(invMsg);
            setTimeout(function () {
                e.verify();
                done();
            }, 200);
        });        
    })    
})