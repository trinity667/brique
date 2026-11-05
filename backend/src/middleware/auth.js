import jwt from 'jsonwebtoken';
import { forbidden, unauthorized, ah, HttpError } from '../lib/errors.js';
import { logAudit } from '../lib/audit.js';

export function signToken(config, user) {
  // `tv` = version des jetons du compte : un changement de PIN la fait avancer et ferme les anciennes connexions.
  return jwt.sign({ sub: user.id, role: user.role, tv: user.token_version ?? 0 }, config.jwtSecret, {
    expiresIn: config.jwtTtl,
    algorithm: 'HS256',
  });
}

/**
 * Vérifie le jeton PUIS recharge l'utilisateur en base : un compte désactivé
 * ou un rôle changé est pris en compte immédiatement (pas de droits périmés).
 */
export function authenticate({ db, config }) {
  return ah(async (req, _res, next) => {
    const header = req.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) throw unauthorized();
    let payload;
    try {
      payload = jwt.verify(token, config.jwtSecret, { algorithms: ['HS256'] });
    } catch {
      throw unauthorized('Session expirée. Reconnectez-vous.');
    }
    const { rows } = await db.query(
      'select id, name, role, worker_id, active, is_president, token_version, must_change_pin from users where id = $1',
      [payload.sub],
    );
    const u = rows[0];
    if (!u || !u.active) throw unauthorized('Compte désactivé ou introuvable.');
    if ((payload.tv ?? 0) !== u.token_version) throw unauthorized('Votre code a changé : reconnectez-vous.');
    req.user = {
      id: u.id, name: u.name, role: u.role, workerId: u.worker_id, isPresident: u.is_president, mustChangePin: u.must_change_pin,
    };
    // Code provisoire : seul le choix du nouveau code (et se déconnecter) est permis tant qu'il n'est pas fait.
    if (u.must_change_pin && !/^\/api\/auth\/(pin|me|logout)(\?|$)/.test(req.originalUrl)) {
      throw new HttpError(403, "Choisissez d'abord votre propre code PIN.", 'must_change_pin');
    }
    // Présence en ligne : mise à jour espacée, en arrière-plan.
    db.query(
      `update users set last_seen_at = now()
        where id = $1 and (last_seen_at is null or last_seen_at < now() - interval '30 seconds')`,
      [u.id],
    ).catch(() => {});
    next();
  });
}

/** Réserve une route à l'admin. Tout refus est tracé (événement de sécurité). */
export function requireAdmin(db) {
  return ah(async (req, _res, next) => {
    if (req.user?.role !== 'admin') {
      await logAudit(db, req.user, {
        action: 'Accès refusé',
        object: `${req.method} ${req.originalUrl.split('?')[0]}`,
        reason: 'Rôle admin requis',
        security: true,
      });
      throw forbidden();
    }
    next();
  });
}

/** Réserve une route au président (rapports officiels). Tout refus est tracé. */
export function requirePresident(db) {
  return ah(async (req, _res, next) => {
    if (req.user?.role !== 'admin' || !req.user.isPresident) {
      await logAudit(db, req.user, {
        action: 'Accès refusé',
        object: `${req.method} ${req.originalUrl.split('?')[0]}`,
        reason: 'Réservé au président',
        security: true,
      });
      throw forbidden('Réservé au président.');
    }
    next();
  });
}
