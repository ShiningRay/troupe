import * as sinon from 'sinon';
import { Scenario } from '../src/scenario';
import { expect } from 'chai';
import { Appearance } from '../src/appearance';
import { Reference } from '../src/reference';



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

    describe('.findReference', () => {
        it('returns Reference', () => {
            var ref = Scenario.findReference('test')
            expect(test).to.be.instanceof(Reference);
        })
    })
});