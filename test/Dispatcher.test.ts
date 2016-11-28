import { expect } from 'chai';
import mm = require('mm')
import * as sinon from 'sinon';
import Dispatcher from '../src/dispatcher'
import { Scenario } from '../src/scenario';
import { Appearance } from '../src/appearance';
import { Reference } from '../src/reference';
import { MessageType, ResultMessage, InvocationMessage, ErrorMessage } from '../src/messages';



describe('Dispatcher', () => {
    var appearance, ref;
    before(() => {
        mm(Scenario, 'findAppearance', function () {
            return appearance
        })

        mm(Scenario, 'findReference', function () {
            return ref;
        })
    });

    after(() => {
        mm.restore()
    })
    beforeEach(() => {
        ref = {
            $handleResult: function () { },
            $handleEvent: function () { },
            $handleError: function () { }
        };
        appearance = {
            handleInvocation: function () { }
        };
    })

    it('dispatches result message', () => {
        var msg: ResultMessage = {
            from: 'test',
            to: 'test',
            type: MessageType.result,
            reqid: 1,
            result: 'result'
        }
        var e = sinon.mock(ref).expects('$handleResult').once();
        Dispatcher(msg)
        e.verify();
    });

    it('dispatches invocation message', () => {
        var msg = {
            from: 'test',
            to: 'test',
            type: MessageType.invocation,
            reqid: 1,
            method: 'test',
            params: [1, 2]
        }
        var e = sinon.mock(appearance).expects('handleInvocation').once().withArgs(msg);
        Dispatcher(msg as InvocationMessage)
        e.verify();
    });

    it('dispatch error message', () => {
        var msg = {
            from: 'test',
            to: 'test',
            type: MessageType.error,
            reqid: 1,
            name: 'TestError',
            message: 'Just a test',
            stack: ''
        }
        var e = sinon.mock(ref).expects('$handleError').once().withArgs(msg);
        Dispatcher(msg as ErrorMessage)
        e.verify();
    });
})

