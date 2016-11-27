import * as sinon from 'sinon';
import { Scenario } from '../src/scenario';
import { expect } from 'chai';
import { Appearance } from '../src/appearance';



describe('Scenario', () => {
    describe('.sendMessage', () => {
        it('send a message to corresponding transport', () => {
            
        });
    });

    describe('.findAppearance', () => {
        it('returns Appearance', () => {
            var test = Scenario.findAppearance('test')
            expect(test).to.be.instanceof(Appearance);
            expect(test.id).to.eql('test');
        });
    });
});