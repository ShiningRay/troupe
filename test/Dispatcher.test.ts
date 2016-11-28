import {expect} from 'chai';
import mm = require('mm')
import * as sinon from 'sinon';
import Dispatcher from '../src/dispatcher'
import { Scenario } from '../src/scenario';
import { Appearance } from '../src/appearance';
import { Reference } from '../src/reference';
import { MessageType, ResultMessage } from '../src/messages';



describe('Dispatcher', () => {
    var appearance,ref;
    before(() => {
        
        
        mm(Scenario, 'findAppearance', function(){
            return appearance
        })

        mm(Scenario, 'findReference', function(){
            return ref;
        })
    });

    after(() => {
        mm.restore()
    })
    beforeEach(() => {
        ref = {
            $handleResult: function(){}
        };
        appearance = {};
    })
    it('dispatches result message', () => {
        var e = sinon.mock(ref).expects('$handleResult').once();
        Dispatcher({
            from: 'test',
            to: 'test',
            type: MessageType.result,
            reqid: 1,
            result: 'result'
        } as ResultMessage)
        e.verify();
    });

    describe('on result message', () => {
    
    });
})

