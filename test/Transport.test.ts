import * as sinon from 'sinon';
import { Transport } from '../src/transport';
import { NullTransport } from '../src/transport/null';
import { Stage } from '../src/stage';
import { expect } from 'chai';

describe('Transport', () => {
    var transport
    beforeEach(() => {
        transport = new NullTransport(Stage.current);
    })

    it('receive object', (done) => {
        transport.write({test: 'test'})
        transport.on('data', (data) => {
            expect(data).to.be.a('object')
            expect(data.test).to.eql('test')
            done()
        })
    });

});